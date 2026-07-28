import Foundation

public struct IPInfoLiteResponse: Decodable, Equatable, Sendable {
    public let ip: String
    public let countryCode: String

    enum CodingKeys: String, CodingKey {
        case ip
        case countryCode = "country_code"
    }
}

public struct FreeIPAPIResponse: Decodable, Equatable, Sendable {
    public let countryCode: String?
}

public struct GeoJSCountryResponse: Decodable, Equatable, Sendable {
    public let country: String
}

public enum GeoResponses {

    private static let decoder = JSONDecoder()

    public static func decodeIPInfo(_ data: Data) throws -> IPInfoLiteResponse {
        try decoder.decode(IPInfoLiteResponse.self, from: data)
    }

    public static func decodeFreeIPAPI(_ data: Data) throws -> String? {
        let code = try decoder.decode(FreeIPAPIResponse.self, from: data).countryCode
        guard let code, !code.isEmpty else { return nil }
        return code
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
            primaryCountry: ipinfo.countryCode,
            confirmedCountry: confirmedCountry,
            confirmSource: source
        )
    }
}
