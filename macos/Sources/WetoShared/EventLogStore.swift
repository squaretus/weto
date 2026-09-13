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
        events = Self.capped(storage.load())

        // Перенос из настроек: история пользователя не выбрасывается, а ключ
        // из plist убирается — иначе он остаётся мёртвым грузом навсегда.
        if let defaults, events.isEmpty, let data = defaults.data(forKey: Self.legacyKey) {
            // Ёмкость применяется и здесь: прежняя запись описывала проход целиком,
            // и десять записей на живой машине — это две с лишним сотни процессов.
            // Развёрнутые по одному, они не влезают в журнал.
            events = Self.capped((try? KillEvent.decodeLog(data)) ?? [])
            if !events.isEmpty { storage.save(events) }
            defaults.removeObject(forKey: Self.legacyKey)
        }
    }

    /// Свежие сверху, лишнее снизу.
    private static func capped(_ events: [KillEvent]) -> [KillEvent] {
        events.count > Constants.eventLogCapacity
            ? Array(events.prefix(Constants.eventLogCapacity))
            : events
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

    /// Уточнение причины и исхода у всех записей эпизода.
    ///
    /// Пауза приходит с причиной — её приносит плохой результат пробы, — но не с исходом:
    /// в журнале остаётся «сервисы не ответили», а чем стояние кончилось, известно
    /// секундами позже. Новой записи к тому моменту не будет: те же процессы либо
    /// возобновлены, либо завершены, и второй набор записей о них был бы ложью. Журнал
    /// навсегда сохранял отговорку вместо того, чем всё кончилось. Уточняется весь
    /// эпизод, а не одна запись: процессов в нём десятки, и причина у них общая.
    ///
    /// `reasonText` необязателен ровно поэтому: причина названа верно с самого начала,
    /// и у эпизода паузы меняется только исход.
    ///
    /// `matchedBy` сужает уточнение до одного основания записи: шелл в плане паузы
    /// не завершается вместе с целью — его SIGCONT продолжает, — и исход у него честнее
    /// сказать отдельным вызовом, не трогая записи с другим основанием того же эпизода.
    ///
    /// `pids` сужает до перечисленных процессов, `skipping` — наоборот, оставляет их
    /// в покое. Оба нужны одному и тому же: процесс, снятый пользователем с охраны,
    /// продолжается своим проходом и получает свой исход, а общий исход эпизода,
    /// пришедший позже, не имеет права переписать его чужим — стояние у этой записи
    /// кончилось раньше и по другой причине.
    public func refine(
        episodeID: UUID,
        matchedBy: MatchBasis? = nil,
        pids: Set<Int32>? = nil,
        skipping: Set<Int32> = [],
        reasonText: String? = nil,
        resolutionText: String? = nil,
        ip: String? = nil,
        country: String? = nil,
        confirmedCountry: String? = nil,
        confirmSource: String? = nil,
        diagnostics: KillDiagnostics? = nil
    ) {
        var touched = false
        for index in events.indices
        where events[index].episodeID == episodeID
            && (matchedBy == nil || events[index].matchedBy == matchedBy)
            && (pids == nil || pids?.contains(events[index].pid) == true)
            && !skipping.contains(events[index].pid) {
            let event = events[index]
            events[index] = KillEvent(
                id: event.id,
                episodeID: event.episodeID,
                date: event.date,
                targetName: event.targetName,
                pid: event.pid,
                parentPID: event.parentPID,
                executablePath: event.executablePath,
                matchedBy: event.matchedBy,
                kind: event.kind,
                reasonText: reasonText ?? event.reasonText,
                resolutionText: resolutionText ?? event.resolutionText,
                ip: ip ?? event.ip,
                country: country ?? event.country,
                confirmedCountry: confirmedCountry ?? event.confirmedCountry,
                confirmSource: confirmSource ?? event.confirmSource,
                diagnostics: diagnostics ?? event.diagnostics
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
