import Foundation

public struct IPInfoLiteResponse: Decodable, Equatable, Sendable {
    public let ip: String
    public let asn: String?
    public let asName: String?
    public let countryCode: String
    public let country: String?

    enum CodingKeys: String, CodingKey {
        case ip
        case asn
        case asName = "as_name"
        case countryCode = "country_code"
        case country
    }
}

public struct IPWhoIsResponse: Decodable, Equatable, Sendable {
    public let success: Bool
    public let countryCode: String?

    enum CodingKeys: String, CodingKey {
        case success
        case countryCode = "country_code"
    }
}

public struct GeoJSCountryResponse: Decodable, Equatable, Sendable {
    public let country: String
    public let ip: String
}

public enum GeoResponses {

    private static let decoder = JSONDecoder()

    public static func decodeIPInfo(_ data: Data) throws -> IPInfoLiteResponse {
        try decoder.decode(IPInfoLiteResponse.self, from: data)
    }

    public static func decodeIPWhoIs(_ data: Data) throws -> String? {
        let response = try decoder.decode(IPWhoIsResponse.self, from: data)
        guard response.success else { return nil }
        return response.countryCode
    }

    public static func decodeGeoJS(_ data: Data) throws -> String? {
        try decoder.decode(GeoJSCountryResponse.self, from: data).country
    }

    public static func makeReading(
        ipinfo: IPInfoLiteResponse,
        confirmedCountry: String?,
        source: ConfirmSource?
    ) -> GeoReading {
        GeoReading(
            ip: ipinfo.ip,
            asn: ipinfo.asn,
            primaryCountry: ipinfo.countryCode,
            confirmedCountry: confirmedCountry,
            confirmSource: source
        )
    }
}
