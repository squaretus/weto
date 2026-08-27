import Foundation

public enum KillEventKind: String, Codable, Equatable, Sendable {

    case terminated

    case launchBlocked

    public var displayText: String {
        switch self {
        case .terminated: return "завершено"
        case .launchBlocked: return "запуск запрещён"
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
    public let isDescendant: Bool

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
        isDescendant: Bool = false,
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
        self.isDescendant = isDescendant
        self.kind = kind
        self.reasonText = reasonText
        self.resolutionText = resolutionText
        self.ip = ip
        self.country = country
        self.confirmedCountry = confirmedCountry
        self.confirmSource = confirmSource
        self.diagnostics = diagnostics
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

extension UnsafeReason {

    public var displayText: String {
        switch self {
        case .verificationPending:
            return "Подключение ещё не проверено"
        case .vpnAppNotChosen:
            return "VPN-приложение не выбрано в настройках"
        case .vpnAppNotRunning:
            return "VPN-приложение не запущено"
        case .geoUnavailable(let detail):
            return "Не удалось определить внешний адрес: \(detail)"
        case .blacklistedIP(let ip):
            return "Адрес \(ip) в чёрном списке"
        case .blockedCountry(let code, let source):
            return "Обнаружена страна \(code) по данным \(source)"
        case .confirmationUnavailable:
            return "Подтверждающие сервисы недоступны"
        case .countryConflict(let primary, let confirmed):
            return "Расхождение стран: ipinfo — \(primary), подтверждение — \(confirmed)"
        case .notWhitelistedIP(let ip):
            return "Адрес \(ip) не входит в белый список"
        case .notWhitelistedCountry(let code):
            return "Страна \(code) не входит в белый список"
        }
    }

    public var isDegradedRatherThanBlocked: Bool {
        switch self {
        case .confirmationUnavailable, .geoUnavailable: return true
        default: return false
        }
    }

    public var statusTitle: String {
        switch self {
        case .verificationPending:
            return "Проверка подключения"
        case .geoUnavailable:
            return "Ipinfo недоступен"
        case .confirmationUnavailable:
            return "Подтверждение недоступно"
        default:
            return "Цели завершены"
        }
    }
}
