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
           let decoded = try? KillEvent.decodeLog(data) {
            events = decoded
        }
    }

    public convenience init() {
        self.init(defaults: UserDefaults(suiteName: Constants.userDefaultsSuite) ?? .standard)
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
        guard let data = try? KillEvent.encodeLog(events) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
