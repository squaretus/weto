import Foundation

public enum KillEventKind: String, Codable, Equatable, Sendable {

    case terminated

    case launchBlocked

    /// Процесс остановлен (SIGSTOP), а не завершён. Чем кончилось стояние —
    /// в `resolutionText`: возобновлено, завершено по доказательству или по потолку.
    case paused

    public var displayText: String {
        switch self {
        case .terminated: return "завершено"
        case .launchBlocked: return "запуск запрещён"
        case .paused: return "на паузе"
        }
    }
}

/// Один завершённый процесс.
///
/// Раньше запись описывала проход охраны целиком: «claude» и тридцать четыре pid
/// одной строкой. По такой записи нельзя ответить на главный вопрос — что именно
/// завершилось и почему их столько, — а ради этого журнал и ведётся. Проход
/// склеивается `episodeID`: тридцать четыре записи об одном падении VPN остаются
/// одним событием и в интерфейсе, и в выгрузке.
public struct KillEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID

    /// Общий для всех процессов, завершённых одним проходом охраны.
    public let episodeID: UUID

    public let date: Date

    public let targetName: String
    public let pid: Int32
    public let parentPID: Int32
    public let executablePath: String

    /// Процесс попал под охрану не сам по себе, а как потомок совпавшего.
    /// Именно потомки объясняют, почему у одной цели десятки записей.
    public let matchedBy: MatchBasis

    public let kind: KillEventKind
    public let reasonText: String

    /// Чем эпизод закончился.
    ///
    /// Fail-closed завершает цели раньше вердикта, и причина у записи — «подключение
    /// ещё не проверено». Через секунду вердикт готов, но завершать уже нечего,
    /// и запись навсегда оставалась с этой отговоркой: по журналу выходило, что
    /// процессы умирают без причины. Исход дописывается и тогда, когда проверка
    /// в итоге сказала «безопасно», — именно этот случай и выглядит как
    /// «рандомно завершает процессы».
    public let resolutionText: String?

    public let ip: String?
    public let country: String?
    public let confirmedCountry: String?
    public let confirmSource: String?

    /// Отладочные показания: в интерфейсе не появляются, уходят в выгрузку.
    public let diagnostics: KillDiagnostics?

    public init(
        id: UUID = UUID(),
        episodeID: UUID,
        date: Date,
        targetName: String,
        pid: Int32,
        parentPID: Int32 = 0,
        executablePath: String = "",
        matchedBy: MatchBasis = .rule,
        kind: KillEventKind,
        reasonText: String,
        resolutionText: String? = nil,
        ip: String?,
        country: String?,
        confirmedCountry: String? = nil,
        confirmSource: String? = nil,
        diagnostics: KillDiagnostics? = nil
    ) {
        self.id = id
        self.episodeID = episodeID
        self.date = date
        self.targetName = targetName
        self.pid = pid
        self.parentPID = parentPID
        self.executablePath = executablePath
        self.matchedBy = matchedBy
        self.kind = kind
        self.reasonText = reasonText
        self.resolutionText = resolutionText
        self.ip = ip
        self.country = country
        self.confirmedCountry = confirmedCountry
        self.confirmSource = confirmSource
        self.diagnostics = diagnostics
    }

    private enum CodingKeys: String, CodingKey {
        case id, episodeID, date, targetName, pid, parentPID, executablePath, matchedBy, isDescendant,
             kind, reasonText, resolutionText, ip, country, confirmedCountry, confirmSource, diagnostics
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        episodeID = try c.decode(UUID.self, forKey: .episodeID)
        date = try c.decode(Date.self, forKey: .date)
        targetName = try c.decode(String.self, forKey: .targetName)
        pid = try c.decode(Int32.self, forKey: .pid)
        parentPID = try c.decodeIfPresent(Int32.self, forKey: .parentPID) ?? 0
        executablePath = try c.decodeIfPresent(String.self, forKey: .executablePath) ?? ""
        // Журналы до переименования писали булев признак: читаем его, но не пишем.
        if let basis = try c.decodeIfPresent(MatchBasis.self, forKey: .matchedBy) {
            matchedBy = basis
        } else {
            matchedBy = (try c.decodeIfPresent(Bool.self, forKey: .isDescendant) ?? false) ? .descendant : .rule
        }
        kind = try c.decode(KillEventKind.self, forKey: .kind)
        reasonText = try c.decode(String.self, forKey: .reasonText)
        resolutionText = try c.decodeIfPresent(String.self, forKey: .resolutionText)
        ip = try c.decodeIfPresent(String.self, forKey: .ip)
        country = try c.decodeIfPresent(String.self, forKey: .country)
        confirmedCountry = try c.decodeIfPresent(String.self, forKey: .confirmedCountry)
        confirmSource = try c.decodeIfPresent(String.self, forKey: .confirmSource)
        diagnostics = try c.decodeIfPresent(KillDiagnostics.self, forKey: .diagnostics)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(episodeID, forKey: .episodeID)
        try c.encode(date, forKey: .date)
        try c.encode(targetName, forKey: .targetName)
        try c.encode(pid, forKey: .pid)
        try c.encode(parentPID, forKey: .parentPID)
        try c.encode(executablePath, forKey: .executablePath)
        try c.encode(matchedBy, forKey: .matchedBy)
        try c.encode(kind, forKey: .kind)
        try c.encode(reasonText, forKey: .reasonText)
        try c.encodeIfPresent(resolutionText, forKey: .resolutionText)
        try c.encodeIfPresent(ip, forKey: .ip)
        try c.encodeIfPresent(country, forKey: .country)
        try c.encodeIfPresent(confirmedCountry, forKey: .confirmedCountry)
        try c.encodeIfPresent(confirmSource, forKey: .confirmSource)
        try c.encodeIfPresent(diagnostics, forKey: .diagnostics)
    }

    public var summaryText: String {
        "\(kind.displayText) — \(Self.lowercasingFirstWord(reasonText))"
    }

    private static func lowercasingFirstWord(_ text: String) -> String {
        let scalars = Array(text)
        guard scalars.count >= 2 else { return text.lowercased() }
        if scalars[0].isUppercase && scalars[1].isUppercase { return text }
        return scalars[0].lowercased() + String(scalars.dropFirst())
    }
}

// MARK: - Чтение журнала

extension KillEvent {

    /// Журнал прежнего формата не выбрасывается: он и есть история, ради которой
    /// поднимали ёмкость. Одна старая запись про N процессов разворачивается
    /// в N записей одного эпизода.
    ///
    /// Разворачивание живёт здесь, а не в `init(from:)`: один элемент массива
    /// обязан превратиться в несколько, и на уровне элемента это невыразимо.
    public static func decodeLog(_ data: Data) throws -> [KillEvent] {
        let decoder = JSONDecoder()
        if let current = try? decoder.decode([KillEvent].self, from: data) {
            return current
        }
        return try decoder.decode([LegacyKillEvent].self, from: data).flatMap(\.expanded)
    }

    public static func encodeLog(_ events: [KillEvent]) throws -> Data {
        try JSONEncoder().encode(events)
    }
}

/// Запись журнала до разбивки на процессы.
private struct LegacyKillEvent: Decodable {
    let id: UUID
    let date: Date
    let targetNames: [String]
    let kind: KillEventKind
    let reasonText: String
    let ip: String?
    let country: String?
    let confirmedCountry: String?
    let confirmSource: String?
    let killedPIDs: [Int32]

    /// Какой pid какой цели принадлежал, прежний формат не сохранял. Выдумывать
    /// привязку нельзя, поэтому цели перечисляются как есть — ровно та точность,
    /// которая была в исходной записи.
    var expanded: [KillEvent] {
        let name = targetNames.isEmpty ? "неизвестная цель" : targetNames.joined(separator: ", ")
        return killedPIDs.map { pid in
            KillEvent(
                episodeID: id,
                date: date,
                targetName: name,
                pid: pid,
                kind: kind,
                reasonText: reasonText,
                ip: ip,
                country: country,
                confirmedCountry: confirmedCountry,
                confirmSource: confirmSource
            )
        }
    }
}

extension UnprovenReason {
    public var displayText: String {
        switch self {
        case .geoUnavailable(let detail): return "Не удалось определить внешний адрес: \(detail)"
        case .addressChanged(let observed): return "Адрес сменился на \(observed), страна не проверена"
        case .confirmationUnavailable: return "Подтверждающие сервисы недоступны"
        }
    }
}

extension UnsafeEvidence {
    public var displayText: String {
        switch self {
        case .vpnAppNotRunning: return "VPN-приложение не запущено"
        case .blacklistedIP(let ip): return "Адрес \(ip) в чёрном списке"
        case .blockedCountry(let code, let source): return "Обнаружена страна \(code) по данным \(source)"
        case .countryConflict(let primary, let confirmed):
            return "Расхождение стран: ipinfo — \(primary), подтверждение — \(confirmed)"
        case .notWhitelistedIP(let ip): return "Адрес \(ip) не входит в белый список"
        case .notWhitelistedCountry(let code): return "Страна \(code) не входит в белый список"
        case .pauseExpired: return "Подтверждение не получено за \(Int(Constants.pauseCeilingSeconds)) с"
        }
    }
}
