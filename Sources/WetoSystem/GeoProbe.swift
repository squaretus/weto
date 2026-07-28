import Foundation
import WetoCore

public protocol GeoProbing: Sendable {
    func probe() async -> GeoOutcome
}

public actor GeoProbe: GeoProbing {

    private let fetcher: HTTPFetching
    private let confirmationFetcher: HTTPFetching
    private let token: @Sendable () -> String?

    public init(
        fetcher: HTTPFetching,
        confirmationFetcher: HTTPFetching? = nil,
        token: @escaping @Sendable () -> String?
    ) {
        self.fetcher = fetcher
        self.confirmationFetcher = confirmationFetcher ?? fetcher
        self.token = token
    }

    public func probe() async -> GeoOutcome {
        guard let token = token(), !token.isEmpty else {
            return .unavailable("не задан токен ipinfo")
        }
        guard let url = URL(string: Constants.ipinfoLiteURL) else {
            return .unavailable("некорректный URL ipinfo")
        }

        let ipinfo: IPInfoLiteResponse
        do {
            let data = try await fetcher.data(from: url, headers: ["Authorization": "Bearer \(token)"])
            ipinfo = try GeoResponses.decodeIPInfo(data)
        } catch {
            return .unavailable(error.localizedDescription)
        }

        // Адрес идёт в URL подтверждающих сервисов, поэтому проверяется до запроса.
        guard IPAddress.isValid(ipinfo.ip) else {
            return .unavailable("ipinfo вернул некорректный адрес")
        }

        // Ни адрес, ни страна, ни подтверждение не кэшируются: решение о завершении
        // целей принимается только по данным, полученным в этой пробе.
        let confirmation = await confirm(ip: ipinfo.ip)

        return .resolved(GeoResponses.makeReading(
            ipinfo: ipinfo,
            confirmedCountry: confirmation?.country,
            source: confirmation?.source
        ))
    }

    private func confirm(ip: String) async -> (country: String, source: ConfirmSource)? {
        if let country = await fetchCountry(
            urlString: Constants.freeipapiURL(ip: ip),
            decode: GeoResponses.decodeFreeIPAPI
        ) {
            return (country, .freeipapi)
        }
        if let country = await fetchCountry(
            urlString: Constants.geojsURL(ip: ip),
            decode: GeoResponses.decodeGeoJS
        ) {
            return (country, .geojs)
        }
        return nil
    }

    private func fetchCountry(
        urlString: String,
        decode: (Data) throws -> String?
    ) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        do {
            return try decode(try await confirmationFetcher.data(from: url, headers: [:]))
        } catch {
            return nil
        }
    }
}
