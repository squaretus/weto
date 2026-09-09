import Foundation
import Observation
import WetoCore

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

public protocol StoppedLedgerPersisting: Sendable {
    func load() -> [StoppedProcess]
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

    public func load() -> [StoppedProcess] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        return (try? JSONDecoder().decode([StoppedProcess].self, from: data)) ?? []
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

    public func load() -> [StoppedProcess] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    public func save(_ entries: [StoppedProcess]) {
        lock.lock(); self.entries = entries; lock.unlock()
    }
}

@MainActor
public final class StoppedLedger {

    public private(set) var entries: [StoppedProcess]
    private let storage: StoppedLedgerPersisting

    public init(storage: StoppedLedgerPersisting) {
        self.storage = storage
        self.entries = storage.load()
    }

    public convenience init() {
        guard let file = StoppedFile() else {
            self.init(storage: InMemoryStoppedLedger())
            return
        }
        self.init(storage: file)
    }

    public var pids: [Int32] { entries.map(\.pid) }

    /// Порядок добавления сохраняется: продолжение идёт по нему в обратную сторону.
    public func add(_ fresh: [StoppedProcess]) {
        let known = Set(pids)
        let additions = fresh.filter { !known.contains($0.pid) }
        guard !additions.isEmpty else { return }
        entries.append(contentsOf: additions)
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
