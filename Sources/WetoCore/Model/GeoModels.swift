import Foundation

/// Состояние выбранного в настройках VPN-сервиса.
public enum VPNStatus: Equatable, Sendable {
    /// В настройках не выбран сервис.
    case notConfigured
    /// Сервис есть в системе, но адреса на нём нет — туннель не поднят.
    case down
    /// Туннель поднят. `isPrimary` — держит ли он default route.
    case up(isPrimary: Bool)
}

/// Какой сервис подтвердил страну известного IP.
public enum ConfirmSource: String, Equatable, Codable, Sendable {
    case ipwhois
    case geojs
}

/// Снятое показание о внешнем адресе.
///
/// `primaryCountry` всегда приходит от ipinfo — единственного источника, которому
/// доверен сам IP (см. раздел 5 спеки: остальные сервисы при split-routing
/// отвечают про посторонний адрес). `confirmedCountry == nil` означает, что оба
/// подтверждающих сервиса не ответили.
public struct GeoReading: Equatable, Sendable {
    public let ip: String
    public let asn: String?
    public let primaryCountry: String
    public let confirmedCountry: String?
    public let confirmSource: ConfirmSource?

    public init(
        ip: String,
        asn: String?,
        primaryCountry: String,
        confirmedCountry: String?,
        confirmSource: ConfirmSource?
    ) {
        self.ip = ip
        self.asn = asn
        self.primaryCountry = primaryCountry
        self.confirmedCountry = confirmedCountry
        self.confirmSource = confirmSource
    }
}

/// Итог сетевой пробы.
///
/// `.unavailable` означает отказ именно ipinfo: без него нет IP, а значит нет и
/// предмета для разговора. Отказ подтверждающих сервисов при живом ipinfo
/// выражается как `.resolved` с `confirmedCountry == nil`.
public enum GeoOutcome: Equatable, Sendable {
    case resolved(GeoReading)
    case unavailable(String)
}
