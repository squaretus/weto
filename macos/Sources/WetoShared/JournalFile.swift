import Foundation
import WetoCore

/// Где лежит журнал и как он туда попадает.
///
/// За протоколом — чтобы хранилище проверялось на временном каталоге, а не
/// в домашнем каталоге того, кто гоняет тесты.
public protocol EventLogPersisting: Sendable {
    func load() -> [KillEvent]
    func save(_ events: [KillEvent])
}

/// Журнал файлом рядом с настройками, но не внутри них.
///
/// В `UserDefaults` он лежать перестал: запись теперь на процесс, ёмкость — сто,
/// а в записи едет диагностика вплоть до сырых ответов гео-сервисов. Всё это
/// в plist настроек означало бы сотни килобайт, читаемых целиком при каждом
/// старте — plist читается весь и сразу, выборочно оттуда не берут.
///
/// Запись атомарная, через временный файл и переименование: журнал переживает
/// и падение, и убийство процесса по SIGKILL, которое для weto штатно.
public struct JournalFile: EventLogPersisting {

    public static let directoryName = "weto"
    public static let fileName = "journal.json"

    private let url: URL
    private let fileManager: FileManager

    public init?(
        directory: URL? = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(JournalFile.directoryName, isDirectory: true),
        fileManager: FileManager = .default
    ) {
        guard let directory else { return nil }
        self.url = directory.appendingPathComponent(Self.fileName)
        self.fileManager = fileManager
    }

    public var path: String { url.path }

    /// Испорченный журнал не должен мешать охране: он не данные пользователя,
    /// а история. Читается как пустой.
    public func load() -> [KillEvent] {
        guard let data = fileManager.contents(atPath: url.path) else { return [] }
        return (try? KillEvent.decodeLog(data)) ?? []
    }

    public func save(_ events: [KillEvent]) {
        guard let data = try? KillEvent.encodeLog(events) else { return }

        let directory = url.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let temporary = url.appendingPathExtension("tmp")
        guard (try? data.write(to: temporary)) != nil else { return }
        _ = try? fileManager.replaceItemAt(url, withItemAt: temporary)
    }
}

/// Журнал без диска: запасной путь, когда каталога Application Support нет,
/// и рабочее хранилище тестов.
public final class InMemoryEventLog: EventLogPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [KillEvent] = []

    public init() {}

    public func load() -> [KillEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    public func save(_ events: [KillEvent]) {
        lock.lock(); self.events = events; lock.unlock()
    }
}
