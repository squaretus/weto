import Foundation

/// Проход охраны так, как его читают в окне: строка на эпизод, а не на процесс.
///
/// Запись журнала описывает процесс, и для разбора это правильно: выгрузка отвечает,
/// что именно встало и почему их столько. В окне pid не говорит ничего, а одно
/// падение VPN на дереве claude давало десятки одинаковых строк подряд, и за ними
/// не было видно истории. Поэтому окно склеивает записи по `episodeID`,
/// а процессы поимённо остаются в выгрузке. Тексты общие с Linux дословно.
public struct JournalEpisode: Identifiable, Equatable, Sendable {

    public let id: UUID

    /// Записи эпизода в порядке журнала: свежие первыми. Не пуст никогда.
    public let events: [KillEvent]

    /// Склейка журнала по эпизодам. Строка стоит там, где эпизод последний раз что-то
    /// записал: процесс, вставший под уже идущей паузой, пишется тем же эпизодом позже
    /// и поверх чужих записей.
    public static func group(_ events: [KillEvent]) -> [JournalEpisode] {
        var order: [UUID] = []
        var members: [UUID: [KillEvent]] = [:]
        for event in events {
            if members[event.episodeID] == nil { order.append(event.episodeID) }
            members[event.episodeID, default: []].append(event)
        }
        return order.map { JournalEpisode(id: $0, events: members[$0] ?? []) }
    }

    /// Запись, с которой эпизод начался: её время, причина и выход объясняют,
    /// почему встали цели.
    private var opening: KillEvent { events[events.count - 1] }

    public var date: Date { opening.date }

    /// Цели, а не процессы: каждая один раз, в порядке, в каком эпизод их задел.
    public var title: String {
        let names = Self.distinct(events.reversed().map(\.targetName))
            .map { $0.isEmpty ? "неизвестная цель" : $0 }
        return names.joined(separator: ", ")
    }

    public var summaryText: String { opening.summaryText }

    /// Исход эпизода отдельной строкой: именно он объясняет запись «подключение ещё
    /// не проверено», после которой всё оказалось в порядке.
    ///
    /// У шелла исход свой — «продолжен: цель завершена …», — а строка рассказывает
    /// про цели, поэтому шелловый исход виден, только когда других нет.
    public var resolutionLine: String? {
        let chronological = Array(events.reversed())
        let targets = chronological.filter { $0.matchedBy != .shell }.compactMap(\.resolutionText)
        let resolutions = Self.distinct(targets.isEmpty ? chronological.compactMap(\.resolutionText) : targets)
        guard !resolutions.isEmpty else { return nil }
        return "Итог: " + resolutions.joined(separator: "; ")
    }

    public var processCount: Int { Set(events.map(\.pid)).count }

    /// Время приходит готовой строкой: формат — забота интерфейса. Адрес назван
    /// всегда, даже неизвестный, — пропуск читался бы как «адрес не спрашивали».
    public func diagnosticsText(timestamp: String) -> String {
        var parts = [timestamp, "IP: \(opening.ip ?? "неизвестен")"]
        if let country = opening.country { parts.append("ipinfo: \(country)") }
        if let confirmed = opening.confirmedCountry {
            parts.append("\(opening.confirmSource ?? "подтверждение"): \(confirmed)")
        }
        if processCount > 1 { parts.append("процессов: \(processCount)") }
        return parts.joined(separator: " · ")
    }

    private static func distinct(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
