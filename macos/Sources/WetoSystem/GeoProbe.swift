import Foundation
import WetoCore

public protocol GeoProbing: Sendable {
    func probe() async -> GeoProbeReport
}

public actor GeoProbe: GeoProbing {

    private let fetcher: HTTPFetching
    private let confirmationFetcher: HTTPFetching
    private let networkPath: NetworkPathReporting
    private let token: @Sendable () -> String?
    private let now: @Sendable () -> Date

    /// Последний годный ответ подтверждающего сервиса. Ключ — адрес: подтверждение
    /// отвечает «в какой стране вот этот адрес», и к другому адресу оно не относится.
    /// Только в памяти: холодный старт и без того fail-closed до первого ответа.
    private var cachedConfirmation: CachedConfirmation?

    private struct CachedConfirmation {
        let ip: String
        let country: String
        let source: ConfirmSource
        let at: Date
    }

    public init(
        fetcher: HTTPFetching,
        confirmationFetcher: HTTPFetching? = nil,
        networkPath: NetworkPathReporting = NetworkPathReporter(),
        token: @escaping @Sendable () -> String?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetcher = fetcher
        self.confirmationFetcher = confirmationFetcher ?? fetcher
        self.networkPath = networkPath
        self.token = token
        self.now = now
    }

    public func probe() async -> GeoProbeReport {
        guard let token = token(), !token.isEmpty else {
            return await fallbackReport(ipinfo: .failed(.other("не задан токен ipinfo")))
        }
        guard let url = URL(string: Constants.ipinfoLiteURL) else {
            return report(ipinfo: .failed(.other("некорректный URL ipinfo")))
        }

        let ipinfo: IPInfoLiteResponse
        do {
            let data = try await fetcher.data(from: url, headers: ["Authorization": "Bearer \(token)"])
            ipinfo = try GeoResponses.decodeIPInfo(data)
        } catch {
            return await fallbackReport(ipinfo: .failed(GeoFailure(error)))
        }

        // Адрес идёт в URL подтверждающих сервисов, поэтому проверяется до запроса.
        guard IPAddress.isValid(ipinfo.ip) else {
            return await fallbackReport(ipinfo: .failed(.other("ipinfo вернул некорректный адрес")))
        }

        // Адрес и основная страна не кэшируются никогда: ipinfo и есть детектор смены
        // страны, и спрашивается он каждый круг. Кэшируется только подтверждение,
        // и только про тот же самый адрес.
        let confirmation = await confirmation(for: ipinfo.ip)

        return GeoProbeReport(
            ip: ipinfo.ip,
            ipinfo: .answered(ipinfo.countryCode),
            confirmation: confirmation.outcome,
            confirmSource: confirmation.source,
            hasNetworkPath: networkPath.hasPath,
            checkedAt: Date()
        )
    }

    /// ipinfo молчит — спрашиваем единственный сервис, который отвечает про звонящего сам.
    ///
    /// Вердикт от этого не становится безопасным: `outcome` требует ответа ipinfo
    /// и остаётся `.unavailable`, то есть fail-closed. Ценность в адресе. Совпал он
    /// с адресом прошлого вердикта — перепроверять страну не нужно, тот же адрес означает
    /// ту же страну; решает это охрана, у которой прошлое чтение и есть. Другой адрес
    /// или молчание обоих сервисов оставляют вердикт недоказанным, и цели завершаются.
    ///
    /// Этим же путём идёт проба без токена: на свежей установке пользователь должен узнать,
    /// где он, ещё до настройки ipinfo.
    private func fallbackReport(
        ipinfo noAnswer: GeoProbeReport.SourceOutcome
    ) async -> GeoProbeReport {
        let noToken = noAnswer

        guard let url = URL(string: Constants.geojsSelfURL) else {
            return report(ipinfo: noToken)
        }

        do {
            let data = try await confirmationFetcher.data(from: url, headers: [:])
            let answer = try GeoResponses.decodeGeoJSSelf(data)
            return GeoProbeReport(
                ip: answer.ip,
                ipinfo: noToken,
                confirmation: .answered(answer.country),
                confirmSource: .geojs,
                hasNetworkPath: networkPath.hasPath,
                checkedAt: Date()
            )
        } catch {
            return GeoProbeReport(
                ip: nil,
                ipinfo: noToken,
                confirmation: .failed(GeoFailure(error)),
                confirmSource: nil,
                hasNetworkPath: networkPath.hasPath,
                checkedAt: Date()
            )
        }
    }

    private func report(ipinfo: GeoProbeReport.SourceOutcome) -> GeoProbeReport {
        GeoProbeReport(
            ip: nil,
            ipinfo: ipinfo,
            confirmation: .notRequested,
            confirmSource: nil,
            hasNetworkPath: networkPath.hasPath,
            checkedAt: Date()
        )
    }

    /// Подтверждение про адрес: из кэша, пока держится мягкий потолок, иначе с попыткой
    /// обновиться. Неудачное обновление в пределах жёсткого потолка оставляет прошлый ответ:
    /// расход по этому сервису делится с соседями по выходу VPN, и его 429 не должен
    /// завершать цели при исправном VPN.
    private func confirmation(
        for ip: String
    ) async -> (outcome: GeoProbeReport.SourceOutcome, source: ConfirmSource?) {
        let cached = cachedConfirmation.flatMap { $0.ip == ip ? $0 : nil }
        let age = cached.map { now().timeIntervalSince($0.at) }

        if let cached, let age, age < Constants.confirmationSoftTTLSeconds {
            return (.answered(cached.country), cached.source)
        }

        let fresh = await confirm(ip: ip)
        if case .answered(let country) = fresh.outcome, let source = fresh.source {
            cachedConfirmation = CachedConfirmation(ip: ip, country: country, source: source, at: now())
            return fresh
        }

        if let cached, let age, age < Constants.confirmationHardTTLSeconds {
            return (.answered(cached.country), cached.source)
        }
        return fresh
    }

    /// Отказ первичного подтверждающего сервиса запоминается: когда молчат оба,
    /// в отчёт идёт его причина, а не общая «недоступность».
    private func confirm(
        ip: String
    ) async -> (outcome: GeoProbeReport.SourceOutcome, source: ConfirmSource?) {
        let primary = await fetchCountry(
            urlString: Constants.freeipapiURL(ip: ip),
            decode: GeoResponses.decodeFreeIPAPI
        )
        if case .success(let country) = primary {
            return (.answered(country), .freeipapi)
        }

        if case .success(let country) = await fetchCountry(
            urlString: Constants.geojsURL(ip: ip),
            decode: GeoResponses.decodeGeoJS
        ) {
            return (.answered(country), .geojs)
        }

        guard case .failure(let failure) = primary else {
            return (.failed(.unreachable), nil)
        }
        return (.failed(failure), nil)
    }

    private func fetchCountry(
        urlString: String,
        decode: (Data) throws -> String?
    ) async -> Result<String, GeoFailure> {
        guard let url = URL(string: urlString) else { return .failure(.other("некорректный URL")) }
        do {
            let country = try decode(try await confirmationFetcher.data(from: url, headers: [:]))
            guard let country else { return .failure(.other("сервис не назвал страну")) }
            return .success(country)
        } catch {
            return .failure(GeoFailure(error))
        }
    }
}

extension GeoFailure {

    /// Перевод ошибки границы в категорию: числа считает `WetoCore`, а сюда попадает
    /// только то, что о них знает Foundation.
    init(_ error: Error) {
        switch error {
        case let http as HTTPFetchError:
            switch http {
            case .badStatus(let code): self = GeoFailure(httpStatus: code)
            }
        case is DecodingError:
            self = .other("непонятный ответ сервиса")
        case let url as URLError:
            self = GeoFailure(urlErrorCode: url.errorCode, description: url.localizedDescription)
        default:
            self = .other(error.localizedDescription)
        }
    }
}
