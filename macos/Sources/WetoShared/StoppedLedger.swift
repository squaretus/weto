import Foundation

/// Процесс, которому weto послал SIGSTOP. Путь хранится ради защиты от переиспользования pid:
/// после падения weto по этому же pid может жить уже другой процесс.
public struct StoppedProcess: Codable, Equatable, Sendable {
    public let pid: Int32
    public let executablePath: String
    public let stoppedAt: Date
    /// Шелл переднего задания — остановлен ради терминала цели, целью не является.
    public let isShell: Bool

    public init(pid: Int32, executablePath: String, stoppedAt: Date, isShell: Bool) {
        self.pid = pid
        self.executablePath = executablePath
        self.stoppedAt = stoppedAt
        self.isShell = isShell
    }
}

/// Итог чтения учёта с диска. Различает «файла нет или он пуст» от «файл был,
/// но не прочитался» — без этого испорченный `stopped.json` неотличим от пустого,
/// и процессы, которых он должен был вернуть из паузы, остаются замороженными молча.
public enum StoppedLedgerReadout: Equatable, Sendable {
    case entries([StoppedProcess])
    case corrupted

    /// Записи независимо от исхода: старт приложения не блокируется ни разу,
    /// испорченный файл читается как пустой ровно как и отсутствующий.
    public var entries: [StoppedProcess] {
        switch self {
        case .entries(let entries): return entries
        case .corrupted: return []
        }
    }

    public var isCorrupted: Bool {
        if case .corrupted = self { return true }
        return false
    }
}

public protocol StoppedLedgerPersisting: Sendable {
    func load() -> StoppedLedgerReadout
    func save(_ entries: [StoppedProcess])
}

/// Учёт рядом с журналами, отдельным файлом: журнал — история, учёт — обязательство.
/// Без него цели, остановленные перед падением weto, остаются замороженными навсегда.
public struct StoppedFile: StoppedLedgerPersisting {

    public static let fileName = "stopped.json"

    private let url: URL

    public init?(
        directory: URL? = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(JournalFile.directoryName, isDirectory: true)
    ) {
        guard let directory else { return nil }
        self.url = directory.appendingPathComponent(Self.fileName)
    }

    public var path: String { url.path }

    /// Файла нет — легитимно пусто, `.entries([])`. Файл есть, но не декодировался —
    /// `.corrupted`: тоже читается как пустой список, но с видимым отличием на границе.
    public func load() -> StoppedLedgerReadout {
        guard let data = FileManager.default.contents(atPath: url.path) else { return .entries([]) }
        guard let decoded = try? JSONDecoder().decode([StoppedProcess].self, from: data) else { return .corrupted }
        return .entries(decoded)
    }

    public func save(_ entries: [StoppedProcess]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = url.appendingPathExtension("tmp")
        guard (try? data.write(to: temporary)) != nil else { return }
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
}

public final class InMemoryStoppedLedger: StoppedLedgerPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [StoppedProcess] = []

    public init() {}

    public func load() -> StoppedLedgerReadout {
        lock.lock(); defer { lock.unlock() }
        return .entries(entries)
    }

    public func save(_ entries: [StoppedProcess]) {
        lock.lock(); self.entries = entries; lock.unlock()
    }
}

@MainActor
public final class StoppedLedger {

    public private(set) var entries: [StoppedProcess]
    /// Истинно, если на старте файл учёта был испорчен: `entries` при этом всё равно
    /// пуст и запуск не заблокирован, но обязательство «вернуть остановленным SIGCONT»
    /// выполнено не было — сигнал виден вызывающему `init(storage:)`, а не тонет в `[]`.
    public let startedFromCorruptedFile: Bool
    private let storage: StoppedLedgerPersisting

    public init(storage: StoppedLedgerPersisting) {
        self.storage = storage
        let readout = storage.load()
        self.entries = readout.entries
        self.startedFromCorruptedFile = readout.isCorrupted
    }

    public convenience init() {
        guard let file = StoppedFile() else {
            self.init(storage: InMemoryStoppedLedger())
            return
        }
        self.init(storage: file)
    }

    public var pids: [Int32] { entries.map(\.pid) }

    /// Запись опознаётся парой «pid + путь» — ровно так же, как её опознают
    /// `ProcessEnforcer.pause` и `settle`. Учёт по одному pid отличать их не мог.
    private struct Identity: Hashable {
        let pid: Int32
        let executablePath: String
    }

    /// Порядок добавления сохраняется: продолжение идёт по нему в обратную сторону.
    ///
    /// Повтором считается та же пара «pid + путь»: она уже стоит в учёте на своём
    /// месте в стоп-порядке, и переписывать её нечем. А вот прежняя запись с тем же
    /// pid, но другим путём, — провально мёртвая: двум живым процессам одно число
    /// ядро не выдаёт. Она уступает место свежей, иначе свежая терялась целиком:
    /// SIGSTOP ей уже послан, в учёт она не попадала, а следующий проход вычёркивал
    /// по несовпадению путей чужую запись — и размораживать цель становилось некому.
    ///
    /// Свежая запись встаёт в хвост, а не на место вытесненной: учёт хранит порядок
    /// остановки, и остановлена она сейчас — позже всего, что в учёте уже лежит.
    public func add(_ fresh: [StoppedProcess]) {
        let known = Set(entries.map { Identity(pid: $0.pid, executablePath: $0.executablePath) })
        let additions = fresh.filter {
            !known.contains(Identity(pid: $0.pid, executablePath: $0.executablePath))
        }
        guard !additions.isEmpty else { return }
        let recycled = Set(additions.map(\.pid))
        entries = entries.filter { !recycled.contains($0.pid) } + additions
        storage.save(entries)
    }

    public func remove(_ pids: [Int32]) {
        let gone = Set(pids)
        let remaining = entries.filter { !gone.contains($0.pid) }
        guard remaining.count != entries.count else { return }
        entries = remaining
        storage.save(entries)
    }

    public func clear() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        storage.save(entries)
    }
}
