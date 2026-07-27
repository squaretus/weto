import Foundation

public enum VPNStatus: Equatable, Sendable {

    case notConfigured

    case down

    case up(isPrimary: Bool)
}

public enum ConfirmSource: String, Equatable, Codable, Sendable {
    case ipwhois
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
    case unavailable(String)
}
