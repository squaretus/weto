import Foundation

/// Ответ `https://v4.api.ipinfo.io/lite/me` — единственный источник внешнего IP.
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

/// Ответ `https://ipwho.is/{ip}`. При ошибке сервис отвечает 200 с `success: false`,
/// поэтому статус-кода недостаточно и флаг надо разбирать явно.
public struct IPWhoIsResponse: Decodable, Equatable, Sendable {
    public let success: Bool
    public let countryCode: String?

    enum CodingKeys: String, CodingKey {
        case success
        case countryCode = "country_code"
    }
}

/// Ответ `https://get.geojs.io/v1/ip/country/{ip}.json`.
public struct GeoJSCountryResponse: Decodable, Equatable, Sendable {
    public let country: String
    public let ip: String
}

/// Разбор ответов гео-сервисов и сборка показания.
public enum GeoResponses {

    private static let decoder = JSONDecoder()

    public static func decodeIPInfo(_ data: Data) throws -> IPInfoLiteResponse {
        try decoder.decode(IPInfoLiteResponse.self, from: data)
    }

    /// Возвращает код страны либо `nil`, если сервис сообщил о неуспехе.
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
