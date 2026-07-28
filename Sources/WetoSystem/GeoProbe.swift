import Foundation
import WetoCore

public protocol GeoProbing: Sendable {
    func probe() async -> GeoOutcome
}

public actor GeoProbe: GeoProbing {

    /// Кэшируется только удачное подтверждение. Отказ не кэшируется вовсе: иначе
    /// единственный сбой обоих сервисов оставлял бы цели заблокированными до смены IP
    /// или перезапуска приложения.
    private struct ConfirmationCache: Sendable {
        let ip: String
        let country: String
        let source: ConfirmSource
        let expiresAt: Date
    }

    private let fetcher: HTTPFetching
    private let confirmationFetcher: HTTPFetching
    private let token: @Sendable () -> String?
    private let now: @Sendable () -> Date

    private var cache: ConfirmationCache?

    public init(
        fetcher: HTTPFetching,
        confirmationFetcher: HTTPFetching? = nil,
        token: @escaping @Sendable () -> String?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetcher = fetcher
        self.confirmationFetcher = confirmationFetcher ?? fetcher
        self.token = token
        self.now = now
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

        let confirmation = await confirmation(for: ipinfo.ip)

        return .resolved(GeoResponses.makeReading(
            ipinfo: ipinfo,
            confirmedCountry: confirmation?.country,
            source: confirmation?.source
        ))
    }

    private func confirmation(for ip: String) async -> (country: String, source: ConfirmSource)? {
        if let cache, cache.ip == ip, cache.expiresAt > now() {
            return (cache.country, cache.source)
        }

        guard let fresh = await confirm(ip: ip) else {
            cache = nil
            return nil
        }

        cache = ConfirmationCache(
            ip: ip,
            country: fresh.country,
            source: fresh.source,
            expiresAt: now().addingTimeInterval(Constants.geoConfirmationTTLSeconds)
        )
        return fresh
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
            return try decode(try await confirmationFetcher.data(from: url, headers: [:]))
        } catch {
            return nil
        }
    }
}
