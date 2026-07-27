import Foundation
import WetoCore

public protocol GeoProbing: Sendable {
    func probe() async -> GeoOutcome
}

public actor GeoProbe: GeoProbing {

    private let fetcher: HTTPFetching
    private let token: @Sendable () -> String?

    private var cachedIP: String?
    private var cachedCountry: String?
    private var cachedSource: ConfirmSource?

    public init(fetcher: HTTPFetching, token: @escaping @Sendable () -> String?) {
        self.fetcher = fetcher
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

        if ipinfo.ip != cachedIP {
            let confirmation = await confirm(ip: ipinfo.ip)
            cachedIP = ipinfo.ip
            cachedCountry = confirmation?.country
            cachedSource = confirmation?.source
        }

        return .resolved(GeoResponses.makeReading(
            ipinfo: ipinfo,
            confirmedCountry: cachedCountry,
            source: cachedSource
        ))
    }

    private func confirm(ip: String) async -> (country: String, source: ConfirmSource)? {
        if let country = await fetchCountry(
            urlString: Constants.ipwhoisURL(ip: ip),
            decode: GeoResponses.decodeIPWhoIs
        ) {
            return (country, .ipwhois)
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
            return try decode(try await fetcher.data(from: url, headers: [:]))
        } catch {
            return nil
        }
    }
}
