import Foundation

public enum VPNStatus: Equatable, Sendable {

    case notConfigured

    case down

    case up(isPrimary: Bool)
}

public enum ConfirmSource: String, Equatable, Codable, Sendable {
    case freeipapi
    case geojs
}

public struct GeoReading: Equatable, Sendable {
    public let ip: String
    public let primaryCountry: String
    public let confirmedCountry: String?
    public let confirmSource: ConfirmSource?

    public init(
        ip: String,
        primaryCountry: String,
        confirmedCountry: String?,
        confirmSource: ConfirmSource?
    ) {
        self.ip = ip
        self.primaryCountry = primaryCountry
        self.confirmedCountry = confirmedCountry
        self.confirmSource = confirmSource
    }
}

public enum GeoOutcome: Equatable, Sendable {
    case resolved(GeoReading)

    /// ipinfo молчит, но резервный сервис назвал наш адрес, и он совпал с адресом
    /// прошлого вердикта. Тот же адрес — та же страна, поэтому круг гео не нужен:
    /// в дело идёт прошлое чтение, и проверки по нему прогоняются полностью.
    /// Снисхождение выдаётся за доказательство неизменности адреса, а не за давность.
    case degraded(previous: GeoReading, detail: String)

    case unavailable(String)

    /// Чтение, по которому принимается решение. `nil` — вердикта нет вовсе.
    public var reading: GeoReading? {
        switch self {
        case .resolved(let reading): return reading
        case .degraded(let previous, _): return previous
        case .unavailable: return nil
        }
    }
}
