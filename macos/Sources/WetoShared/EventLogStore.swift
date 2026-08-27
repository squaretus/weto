import Foundation
import Observation
import WetoCore

@Observable
@MainActor
public final class EventLogStore {

    /// Ключ прежнего хранилища. Остался ради переноса: журнал жил в plist настроек,
    /// который читается целиком при каждом старте.
    private static let legacyKey = "eventLog"

    public private(set) var events: [KillEvent] = []

    @ObservationIgnored private let storage: EventLogPersisting

    public init(storage: EventLogPersisting, migratingFrom defaults: UserDefaults? = nil) {
        self.storage = storage
        events = storage.load()

        // Перенос из настроек: история пользователя не выбрасывается, а ключ
        // из plist убирается — иначе он остаётся мёртвым грузом навсегда.
        if let defaults, events.isEmpty, let data = defaults.data(forKey: Self.legacyKey) {
            events = (try? KillEvent.decodeLog(data)) ?? []
            if !events.isEmpty { storage.save(events) }
            defaults.removeObject(forKey: Self.legacyKey)
        }
    }

    public convenience init() {
        let defaults = UserDefaults(suiteName: Constants.userDefaultsSuite)
        guard let file = JournalFile() else {
            self.init(storage: InMemoryEventLog(), migratingFrom: defaults)
            return
        }
        self.init(storage: file, migratingFrom: defaults)
    }

    /// Проход охраны пишется целиком: сколько процессов завершено, столько
    /// и записей. Порядок внутри прохода сохраняется, сам проход ложится наверх.
    public func record(_ batch: [KillEvent]) {
        guard !batch.isEmpty else { return }
        events.insert(contentsOf: batch, at: 0)
        if events.count > Constants.eventLogCapacity {
            events.removeLast(events.count - Constants.eventLogCapacity)
        }
        persist()
    }

    /// Уточнение причины у всех записей эпизода.
    ///
    /// Fail-closed завершает цели раньше, чем причина известна, и в журнал попадает
    /// «подключение ещё не проверено» — ответ «пока не знаю». Секундой позже вердикт
    /// готов, но завершать уже нечего, и новой записи не будет: журнал навсегда
    /// сохранял отговорку вместо того, из-за чего цели и умерли. Уточняется весь
    /// эпизод, а не одна запись: процессов в нём десятки, и причина у них общая.
    public func refine(
        episodeID: UUID,
        reasonText: String,
        resolutionText: String? = nil,
        ip: String? = nil,
        country: String? = nil,
        confirmedCountry: String? = nil,
        confirmSource: String? = nil
    ) {
        var touched = false
        for index in events.indices where events[index].episodeID == episodeID {
            let event = events[index]
            events[index] = KillEvent(
                id: event.id,
                episodeID: event.episodeID,
                date: event.date,
                targetName: event.targetName,
                pid: event.pid,
                parentPID: event.parentPID,
                executablePath: event.executablePath,
                isDescendant: event.isDescendant,
                kind: event.kind,
                reasonText: reasonText,
                resolutionText: resolutionText ?? event.resolutionText,
                ip: ip ?? event.ip,
                country: country ?? event.country,
                confirmedCountry: confirmedCountry ?? event.confirmedCountry,
                confirmSource: confirmSource ?? event.confirmSource
            )
            touched = true
        }
        guard touched else { return }
        persist()
    }

    public func clear() {
        events.removeAll()
        persist()
    }

    private func persist() {
        storage.save(events)
    }
}
