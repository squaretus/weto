import Foundation
import Observation
import WetoCore

@Observable
@MainActor
public final class EventLogStore {

    private static let key = "eventLog"

    public private(set) var events: [KillEvent] = []

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([KillEvent].self, from: data) {
            events = decoded
        }
    }

    public convenience init() {
        self.init(defaults: UserDefaults(suiteName: Constants.userDefaultsSuite) ?? .standard)
    }

    public func record(_ event: KillEvent) {
        events.insert(event, at: 0)
        if events.count > Constants.eventLogCapacity {
            events.removeLast(events.count - Constants.eventLogCapacity)
        }
        persist()
    }

    /// Уточнение причины у записи текущего эпизода.
    ///
    /// Fail-closed завершает цели раньше, чем причина известна, и в журнал попадает
    /// «подключение ещё не проверено» — ответ «пока не знаю». Секундой позже вердикт
    /// готов, но завершать уже нечего, и новой записи не будет: журнал навсегда
    /// сохранял отговорку вместо того, из-за чего цели и умерли. Показания вердикта
    /// дописываются той же операцией — у пендинга их не было.
    public func refine(
        id: UUID,
        reasonText: String,
        ip: String? = nil,
        country: String? = nil,
        confirmedCountry: String? = nil,
        confirmSource: String? = nil
    ) {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        let event = events[index]
        events[index] = KillEvent(
            id: event.id,
            date: event.date,
            targetNames: event.targetNames,
            kind: event.kind,
            reasonText: reasonText,
            ip: ip ?? event.ip,
            country: country ?? event.country,
            confirmedCountry: confirmedCountry ?? event.confirmedCountry,
            confirmSource: confirmSource ?? event.confirmSource,
            killedPIDs: event.killedPIDs
        )
        persist()
    }

    public func clear() {
        events.removeAll()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
