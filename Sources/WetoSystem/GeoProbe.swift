import Foundation
import WetoCore

/// Граница системы: получение вердикта о внешнем положении машины.
public protocol GeoProbing: Sendable {
    func probe() async -> GeoOutcome
}

/// Опрос гео-сервисов.
///
/// `ipinfo` — единственный источник IP: при split-routing остальные сервисы,
/// отвечая на вопрос «какой у меня адрес», возвращают посторонний IPv6
/// (проверено на машине владельца). Подтверждающий сервис спрашивается про уже
/// известный IP и потому кэшируется: страна фиксированного адреса между
/// опросами не меняется. Это укладывает нас в лимит ipwho.is в 1000 запросов
/// в сутки при опросе раз в 5 секунд.
///
/// Актор, потому что кэш мутируется из фонового цикла и из обработчиков
/// сетевых событий одновременно.
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

    // MARK: - Private

    /// Основной подтверждающий — ipwho.is, резервный — geojs.
    /// geojs именно резервный: его лимит нигде не задокументирован,
    /// а неизвестное ограничение хуже известного.
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
