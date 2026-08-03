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

    public init(
        fetcher: HTTPFetching,
        confirmationFetcher: HTTPFetching? = nil,
        networkPath: NetworkPathReporting = NetworkPathReporter(),
        token: @escaping @Sendable () -> String?
    ) {
        self.fetcher = fetcher
        self.confirmationFetcher = confirmationFetcher ?? fetcher
        self.networkPath = networkPath
        self.token = token
    }

    public func probe() async -> GeoProbeReport {
        guard let token = token(), !token.isEmpty else {
            return report(ipinfo: .failed(.other("не задан токен ipinfo")))
        }
        guard let url = URL(string: Constants.ipinfoLiteURL) else {
            return report(ipinfo: .failed(.other("некорректный URL ipinfo")))
        }

        let ipinfo: IPInfoLiteResponse
        do {
            let data = try await fetcher.data(from: url, headers: ["Authorization": "Bearer \(token)"])
            ipinfo = try GeoResponses.decodeIPInfo(data)
        } catch {
            return report(ipinfo: .failed(GeoFailure(error)))
        }

        // Адрес идёт в URL подтверждающих сервисов, поэтому проверяется до запроса.
        guard IPAddress.isValid(ipinfo.ip) else {
            return report(ipinfo: .failed(.other("ipinfo вернул некорректный адрес")))
        }

        // Ни адрес, ни страна, ни подтверждение не кэшируются: решение о завершении
        // целей принимается только по данным, полученным в этой пробе.
        let confirmation = await confirm(ip: ipinfo.ip)

        return GeoProbeReport(
            ip: ipinfo.ip,
            ipinfo: .answered(ipinfo.countryCode),
            confirmation: confirmation.outcome,
            confirmSource: confirmation.source,
            hasNetworkPath: networkPath.hasPath,
            checkedAt: Date()
        )
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
