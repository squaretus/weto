import Foundation
import WetoCore

/// Журнал проверок подключения.
///
/// Пишется на диск сразу, как и журнал завершений: кнопка выгрузки ничего
/// не собирает заново, она пакует уже написанное. В интерфейс не попадает —
/// это материал для разбора, а не для экрана.
///
/// Не `@Observable`: показывать нечего, и лишние уведомления UI ни к чему.
public final class CheckLogStore: @unchecked Sendable {

    private let lock = NSLock()
    private let storage: CheckLogPersisting
    private var events: [CheckEvent]

    public init(storage: CheckLogPersisting) {
        self.storage = storage
        self.events = Self.capped(storage.load())
    }

    public convenience init() {
        guard let file = ChecksFile() else {
            self.init(storage: InMemoryCheckLog())
            return
        }
        self.init(storage: file)
    }

    public var all: [CheckEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    /// Рутинная удача расписания отсеивается здесь, а не у вызывающего:
    /// решение «что достойно записи» — свойство события, и оно одно на все
    /// места, откуда проверки приходят.
    public func record(_ event: CheckEvent) {
        guard event.isWorthRecording else { return }

        lock.lock()
        events.insert(event, at: 0)
        events = Self.capped(events)
        let snapshot = events
        lock.unlock()

        storage.save(snapshot)
    }

    public func clear() {
        lock.lock()
        events.removeAll()
        lock.unlock()
        storage.save([])
    }

    private static func capped(_ events: [CheckEvent]) -> [CheckEvent] {
        events.count > Constants.checkLogCapacity
            ? Array(events.prefix(Constants.checkLogCapacity))
            : events
    }
}
