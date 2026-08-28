import Foundation

/// Почему прежний вердикт перестал быть свежим.
///
/// Свежесть — пара «ревизия конфигурации + отпечаток снимка сети». Потеряв её,
/// охрана завершает цели ещё до запроса к ipinfo, и в журнал попадает
/// «подключение ещё не проверено». Без этой записи ответить на вопрос
/// «что именно изменилось» нельзя: и правка настроек, и смена интерфейса
/// выглядят одинаково.
public struct VerdictStaleness: Codable, Equatable, Sendable {

    public enum Cause: String, Codable, Sendable {
        /// Вердикта не было вовсе: холодный старт или возврат после `safe`.
        case coldStart
        case configurationChanged
        case networkChanged
        case configurationAndNetworkChanged

        public var displayText: String {
            switch self {
            case .coldStart: return "вердикта ещё не было"
            case .configurationChanged: return "изменились настройки"
            case .networkChanged: return "сменился выход в сеть"
            case .configurationAndNetworkChanged: return "изменились и настройки, и выход в сеть"
            }
        }
    }

    public let cause: Cause
    public let previousRevision: Int?
    public let revision: Int
    public let previousFingerprint: String?
    public let fingerprint: String

    public init(
        previousRevision: Int?,
        revision: Int,
        previousFingerprint: String?,
        fingerprint: String
    ) {
        self.previousRevision = previousRevision
        self.revision = revision
        self.previousFingerprint = previousFingerprint
        self.fingerprint = fingerprint

        switch (previousRevision, previousFingerprint) {
        case (nil, _), (_, nil):
            self.cause = .coldStart
        case (let old?, let oldFingerprint?):
            let configurationChanged = old != revision
            let networkChanged = oldFingerprint != fingerprint
            switch (configurationChanged, networkChanged) {
            case (true, true): self.cause = .configurationAndNetworkChanged
            case (true, false): self.cause = .configurationChanged
            case (false, true): self.cause = .networkChanged
            case (false, false): self.cause = .coldStart
            }
        }
    }

    /// «сменился выход в сеть: utun6/10.2.0.2 → utun6/10.2.0.5» — то, ради чего
    /// диагностика и собирается.
    public var displayText: String {
        guard cause == .networkChanged || cause == .configurationAndNetworkChanged,
              let previousFingerprint
        else { return cause.displayText }
        return "\(cause.displayText): \(previousFingerprint) → \(fingerprint)"
    }
}

/// Что ответил один гео-сервис в одной пробе — как есть, до разбора.
///
/// Сырое тело нужно именно потому, что разобранный ответ уже прошёл через наши
/// предположения: разбирать чужой ответ и одновременно доверять своему разбору —
/// значит не увидеть случай, где предположение неверно.
public struct GeoServiceTrace: Codable, Equatable, Sendable {

    /// Потолок сырого тела. Ответы гео-сервисов — сотни байт; всё, что заметно
    /// больше, это не ответ, а страница-заглушка провайдера или капча,
    /// и для опознания её хватает начала.
    public static let bodyLimit = 4096

    public let service: String

    /// Токена в адресе нет никогда: ipinfo принимает его заголовком, а заголовки
    /// в журнал не попадают вовсе.
    public let url: String

    public let httpStatus: Int?
    public let durationMilliseconds: Int?
    public let body: String?
    public let failure: String?

    /// Ответ взят из кэша подтверждения, а не получен сейчас.
    public let fromCache: Bool
    public let cacheAgeSeconds: Int?

    public init(
        service: String,
        url: String,
        httpStatus: Int? = nil,
        durationMilliseconds: Int? = nil,
        body: String? = nil,
        failure: String? = nil,
        fromCache: Bool = false,
        cacheAgeSeconds: Int? = nil
    ) {
        self.service = service
        self.url = url
        self.httpStatus = httpStatus
        self.durationMilliseconds = durationMilliseconds
        self.body = body.map(Self.trimmed)
        self.failure = failure
        self.fromCache = fromCache
        self.cacheAgeSeconds = cacheAgeSeconds
    }

    public static func trimmed(_ body: String) -> String {
        guard body.count > bodyLimit else { return body }
        return String(body.prefix(bodyLimit)) + "…(обрезано)"
    }
}

/// Всё, что известно о завершении, но не показывается пользователю.
///
/// Живёт в записи журнала и уходит в выгрузку. В интерфейсе не появляется:
/// на экране остаются цель, причина и показания вердикта.
public struct KillDiagnostics: Codable, Equatable, Sendable {

    public let staleness: VerdictStaleness?

    /// Кто выпускал вердиктный запрос наружу: интерфейс и его локальный адрес.
    public let outgoingInterface: String?
    public let outgoingAddress: String?
    public let hasNetworkPath: Bool?

    public let vpnAppEntry: String?
    public let vpnAppStatus: String?

    public let services: [GeoServiceTrace]

    public let probedAt: Date?
    public let appVersion: String?

    public init(
        staleness: VerdictStaleness? = nil,
        outgoingInterface: String? = nil,
        outgoingAddress: String? = nil,
        hasNetworkPath: Bool? = nil,
        vpnAppEntry: String? = nil,
        vpnAppStatus: String? = nil,
        services: [GeoServiceTrace] = [],
        probedAt: Date? = nil,
        appVersion: String? = nil
    ) {
        self.staleness = staleness
        self.outgoingInterface = outgoingInterface
        self.outgoingAddress = outgoingAddress
        self.hasNetworkPath = hasNetworkPath
        self.vpnAppEntry = vpnAppEntry
        self.vpnAppStatus = vpnAppStatus
        self.services = services
        self.probedAt = probedAt
        self.appVersion = appVersion
    }
}
