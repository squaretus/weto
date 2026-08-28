import XCTest
@testable import WetoSystem
import WetoCore

private struct FetchFailure: Error {}

private actor FakeFetcher: HTTPFetching {
    private var responses: [String: Result<Data, Error>]
    private var callCounts: [String: Int] = [:]

    init(responses: [String: Result<Data, Error>]) {
        self.responses = responses
    }

    func fetch(from url: URL, headers: [String: String]) async throws -> HTTPResponse {
        let key = responses.keys.first { url.absoluteString.contains($0) } ?? "unmatched"
        callCounts[key, default: 0] += 1
        guard let result = responses[key] else { throw FetchFailure() }
        return HTTPResponse(data: try result.get(), statusCode: 200, duration: 0.012)
    }

    func count(_ key: String) -> Int { callCounts[key] ?? 0 }
    func setResponse(_ key: String, _ result: Result<Data, Error>) { responses[key] = result }
}

private let geojsSelfKZ = Data(
    #"{"country":"KZ","country_3":"KAZ","ip":"91.224.74.56","name":"Kazakhstan"}"#.utf8
)

private struct FakeNetworkPath: NetworkPathReporting {
    let hasPath: Bool
}

/// Время — граница системы, поэтому подменяется. Потолки кэша иначе пришлось бы
/// ждать по-настоящему.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        value = value.addingTimeInterval(interval)
    }
}

final class GeoProbeTests: XCTestCase {

    func test_report_names_the_service_that_answered() async {
        let fetcher = FakeFetcher(responses: [
            "ipinfo.io": .success(ipinfoData(ip: "203.0.113.28", country: "KZ")),
            "freeipapi": .success(freeipapiKZ),
        ])
        let probe = GeoProbe(
            fetcher: fetcher,
            networkPath: FakeNetworkPath(hasPath: true),
            token: { "t" }
        )

        let report = await probe.probe()

        XCTAssertEqual(report.ip, "203.0.113.28")
        XCTAssertEqual(report.ipinfo, .answered("KZ"))
        XCTAssertEqual(report.confirmation, .answered("KZ"))
        XCTAssertEqual(report.confirmSource, .freeipapi)
        XCTAssertTrue(report.hasNetworkPath)
    }

    func test_report_keeps_why_the_confirmation_refused() async {
        let fetcher = FakeFetcher(responses: [
            "ipinfo.io": .success(ipinfoData(ip: "203.0.113.28", country: "KZ")),
            "freeipapi": .failure(HTTPFetchError(statusCode: 429, response: HTTPResponse(data: Data("rate limit exceeded".utf8), statusCode: 429, duration: 0.005))),
            "geojs.io": .failure(HTTPFetchError(statusCode: 503, response: HTTPResponse(data: Data("service unavailable".utf8), statusCode: 503, duration: 0.004))),
        ])
        let probe = GeoProbe(
            fetcher: fetcher,
            networkPath: FakeNetworkPath(hasPath: true),
            token: { "t" }
        )

        let report = await probe.probe()

        XCTAssertEqual(
            report.confirmation, .failed(.rateLimited(429)),
            "исчерпанный лимит первичного подтверждающего сервиса нельзя выдавать за общую недоступность"
        )
    }

    private func ipinfoData(ip: String, country: String) -> Data {
        Data("""
        {"ip":"\(ip)","asn":"AS49791","as_name":"Newserverlife LLC",
         "country_code":"\(country)","country":"Kazakhstan"}
        """.utf8)
    }

    private let freeipapiKZ = Data(#"{"ipVersion":4,"ipAddress":"203.0.113.28","countryCode":"KZ"}"#.utf8)
    private let geojsKZ = Data(#"{"country":"KZ","country_3":"KAZ","ip":"203.0.113.28","name":"Kazakhstan"}"#.utf8)

    func test_ipinfo_failure_yields_unavailable() async {
        let fetcher = FakeFetcher(responses: ["ipinfo.io": .failure(FetchFailure())])
        let probe = GeoProbe(fetcher: fetcher, token: { "t" })

        guard case .unavailable = await probe.probe().outcome else {
            return XCTFail("ожидался .unavailable")
        }
    }

    /// Токена нет — вердикт остаётся fail-closed, но справочный источник спрашиваем:
    /// на свежей установке пользователю нужно узнать, где он, ещё до настройки ipinfo.
    func test_missing_token_keeps_verdict_unavailable_but_asks_the_reference_source() async {
        let fetcher = FakeFetcher(responses: ["geojs.io": .success(geojsSelfKZ)])
        let probe = GeoProbe(
            fetcher: fetcher,
            networkPath: FakeNetworkPath(hasPath: true),
            token: { nil }
        )

        let report = await probe.probe()

        guard case .unavailable = report.outcome else {
            return XCTFail("без ipinfo вердикт обязан остаться fail-closed")
        }
        XCTAssertEqual(report.ipinfo, .failed(.other("не задан токен ipinfo")))
        XCTAssertEqual(report.confirmation, .answered("KZ"))
        XCTAssertEqual(report.confirmSource, .geojs)
        XCTAssertEqual(report.ip, "91.224.74.56")

        let ipinfoCalls = await fetcher.count("ipinfo.io")
        XCTAssertEqual(ipinfoCalls, 0, "без токена ipinfo спрашивать нечем")
    }

    /// Отказ ipinfo не оставляет нас без адреса: адрес и есть то, по чему потом решают,
    /// нужно ли перепроверять страну. Тот же адрес — та же страна, и круг гео не нужен.
    func test_when_ipinfo_refuses_the_probe_asks_the_reference_source_for_its_own_address() async {
        let fetcher = FakeFetcher(responses: [
            "ipinfo.io": .failure(HTTPFetchError(statusCode: 429, response: HTTPResponse(data: Data("rate limit exceeded".utf8), statusCode: 429, duration: 0.005))),
            "ip/country.json": .success(geojsSelfKZ),
        ])
        let probe = GeoProbe(
            fetcher: fetcher,
            networkPath: FakeNetworkPath(hasPath: true),
            token: { "t" }
        )

        let report = await probe.probe()

        XCTAssertEqual(report.ipinfo, .failed(.rateLimited(429)))
        XCTAssertEqual(report.ip, "91.224.74.56", "без адреса нечем доказать, что он не менялся")
        XCTAssertEqual(report.confirmation, .answered("KZ"))
        XCTAssertEqual(report.confirmSource, .geojs)

        guard case .unavailable = report.outcome else {
            return XCTFail("без ответа ipinfo вердикт обязан остаться fail-closed")
        }
    }

    func test_reference_source_failure_is_shown_instead_of_a_country() async {
        let fetcher = FakeFetcher(responses: ["geojs.io": .failure(HTTPFetchError(statusCode: 503, response: HTTPResponse(data: Data("service unavailable".utf8), statusCode: 503, duration: 0.004)))])
        let probe = GeoProbe(
            fetcher: fetcher,
            networkPath: FakeNetworkPath(hasPath: true),
            token: { "" }
        )

        let report = await probe.probe()

        XCTAssertNil(report.ip)
        XCTAssertEqual(report.confirmation, .failed(GeoFailure(httpStatus: 503)))
    }

    func test_successful_probe_uses_freeipapi_as_confirmation() async {
        let fetcher = FakeFetcher(responses: [
            "ipinfo.io": .success(ipinfoData(ip: "203.0.113.28", country: "KZ")),
            "freeipapi": .success(freeipapiKZ),
        ])
        let probe = GeoProbe(fetcher: fetcher, token: { "t" })

        guard case .resolved(let reading) = await probe.probe().outcome else {
            return XCTFail("ожидался .resolved")
        }
        XCTAssertEqual(reading.ip, "203.0.113.28")
        XCTAssertEqual(reading.primaryCountry, "KZ")
        XCTAssertEqual(reading.confirmedCountry, "KZ")
        XCTAssertEqual(reading.confirmSource, .freeipapi)
    }

    func test_geojs_is_used_when_freeipapi_fails() async {
        let fetcher = FakeFetcher(responses: [
            "ipinfo.io": .success(ipinfoData(ip: "203.0.113.28", country: "KZ")),
            "freeipapi": .failure(FetchFailure()),
            "geojs.io": .success(geojsKZ),
        ])
        let probe = GeoProbe(fetcher: fetcher, token: { "t" })

        guard case .resolved(let reading) = await probe.probe().outcome else {
            return XCTFail("ожидался .resolved")
        }
        XCTAssertEqual(reading.confirmedCountry, "KZ")
        XCTAssertEqual(reading.confirmSource, .geojs)
    }

    func test_both_confirmations_failing_yields_resolved_without_confirmation() async {
        let fetcher = FakeFetcher(responses: [
            "ipinfo.io": .success(ipinfoData(ip: "203.0.113.28", country: "KZ")),
            "freeipapi": .failure(FetchFailure()),
            "geojs.io": .failure(FetchFailure()),
        ])
        let probe = GeoProbe(fetcher: fetcher, token: { "t" })

        guard case .resolved(let reading) = await probe.probe().outcome else {
            return XCTFail("ожидался .resolved, а не .unavailable — IP-то мы получили")
        }
        XCTAssertNil(reading.confirmedCountry)
        XCTAssertNil(reading.confirmSource)
    }

    /// Подтверждение отвечает «в какой стране вот этот адрес». У неизменного адреса ответ
    /// не меняется каждые пять секунд, а квота подтверждающего сервиса считается на адрес
    /// выхода VPN и делится с соседями по узлу — переспрашивать его каждый такт значит
    /// выжигать общий лимит и ловить чужие отказы.
    func test_confirmation_is_not_asked_again_for_the_same_address() async {
        let fetcher = FakeFetcher(responses: [
            "ipinfo.io": .success(ipinfoData(ip: "203.0.113.28", country: "KZ")),
            "freeipapi": .success(freeipapiKZ),
        ])
        let probe = GeoProbe(fetcher: fetcher, token: { "t" })

        for _ in 0..<5 { _ = await probe.probe() }

        let ipinfoCalls = await fetcher.count("ipinfo.io")
        let confirmCalls = await fetcher.count("freeipapi")
        XCTAssertEqual(ipinfoCalls, 5, "ipinfo опрашивается каждый такт: он и есть детектор смены страны")
        XCTAssertEqual(confirmCalls, 1, "адрес тот же — подтверждать нечего")
    }

    /// Страну меняет ipinfo, и это видно в тот же такт: кэшируется подтверждение,
    /// а не основной источник.
    func test_country_change_from_ipinfo_is_seen_immediately() async {
        let fetcher = FakeFetcher(responses: [
            "ipinfo.io": .success(ipinfoData(ip: "203.0.113.28", country: "KZ")),
            "freeipapi": .success(freeipapiKZ),
        ])
        let probe = GeoProbe(fetcher: fetcher, token: { "t" })
        _ = await probe.probe()

        await fetcher.setResponse("ipinfo.io", .success(ipinfoData(ip: "203.0.113.28", country: "RU")))

        guard case .resolved(let reading) = await probe.probe().outcome else {
            return XCTFail("ожидался .resolved")
        }
        XCTAssertEqual(reading.primaryCountry, "RU")
    }

    func test_confirmation_is_refreshed_after_the_soft_ceiling() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let fetcher = FakeFetcher(responses: [
            "ipinfo.io": .success(ipinfoData(ip: "203.0.113.28", country: "KZ")),
            "freeipapi": .success(freeipapiKZ),
        ])
        let probe = GeoProbe(fetcher: fetcher, token: { "t" }, now: { clock.now })
        _ = await probe.probe()

        clock.advance(by: Constants.confirmationSoftTTLSeconds + 1)
        await fetcher.setResponse(
            "freeipapi",
            .success(Data(#"{"ipVersion":4,"ipAddress":"203.0.113.28","countryCode":"RU"}"#.utf8))
        )

        guard case .resolved(let reading) = await probe.probe().outcome else {
            return XCTFail("ожидался .resolved")
        }
        XCTAssertEqual(reading.confirmedCountry, "RU", "по мягкому потолку ответ обязан обновиться")
    }

    /// Неудачное обновление в пределах жёсткого потолка ничего не меняет: у нас есть
    /// годный ответ про этот адрес, и отказ чужого сервиса не повод завершать цели.
    func test_failed_refresh_keeps_the_previous_confirmation() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let fetcher = FakeFetcher(responses: [
            "ipinfo.io": .success(ipinfoData(ip: "203.0.113.28", country: "KZ")),
            "freeipapi": .success(freeipapiKZ),
        ])
        let probe = GeoProbe(fetcher: fetcher, token: { "t" }, now: { clock.now })
        _ = await probe.probe()

        clock.advance(by: Constants.confirmationSoftTTLSeconds + 1)
        await fetcher.setResponse("freeipapi", .failure(HTTPFetchError(statusCode: 429, response: HTTPResponse(data: Data("rate limit exceeded".utf8), statusCode: 429, duration: 0.005))))
        await fetcher.setResponse("ip/country/", .failure(HTTPFetchError(statusCode: 503, response: HTTPResponse(data: Data("service unavailable".utf8), statusCode: 503, duration: 0.004))))

        let report = await probe.probe()

        XCTAssertEqual(report.confirmation, .answered("KZ"))
        XCTAssertEqual(report.confirmSource, .freeipapi)
    }

    func test_after_the_hard_ceiling_a_failed_refresh_drops_the_confirmation() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let fetcher = FakeFetcher(responses: [
            "ipinfo.io": .success(ipinfoData(ip: "203.0.113.28", country: "KZ")),
            "freeipapi": .success(freeipapiKZ),
        ])
        let probe = GeoProbe(fetcher: fetcher, token: { "t" }, now: { clock.now })
        _ = await probe.probe()

        clock.advance(by: Constants.confirmationHardTTLSeconds + 1)
        await fetcher.setResponse("freeipapi", .failure(HTTPFetchError(statusCode: 429, response: HTTPResponse(data: Data("rate limit exceeded".utf8), statusCode: 429, duration: 0.005))))
        await fetcher.setResponse("ip/country/", .failure(HTTPFetchError(statusCode: 503, response: HTTPResponse(data: Data("service unavailable".utf8), statusCode: 503, duration: 0.004))))

        let report = await probe.probe()

        XCTAssertEqual(
            report.confirmation, .failed(.rateLimited(429)),
            "вечно доверять одному подтверждению нельзя: у переприсвоенных диапазонов страна меняется"
        )
    }

    func test_failed_confirmation_recovers_on_the_next_probe() async {
        let fetcher = FakeFetcher(responses: [
            "ipinfo.io": .success(ipinfoData(ip: "203.0.113.28", country: "KZ")),
            "freeipapi": .failure(FetchFailure()),
            "geojs.io": .failure(FetchFailure()),
        ])
        let probe = GeoProbe(fetcher: fetcher, token: { "t" })

        _ = await probe.probe()
        await fetcher.setResponse("freeipapi", .success(freeipapiKZ))

        guard case .resolved(let reading) = await probe.probe().outcome else {
            return XCTFail("ожидался .resolved")
        }
        XCTAssertEqual(reading.confirmedCountry, "KZ")
    }

    func test_malformed_ip_from_ipinfo_is_rejected_without_confirmation_request() async {

        let fetcher = FakeFetcher(responses: [
            "ipinfo.io": .success(ipinfoData(ip: "не адрес", country: "KZ")),
            "freeipapi": .success(freeipapiKZ),
        ])
        let probe = GeoProbe(fetcher: fetcher, token: { "t" })

        guard case .unavailable = await probe.probe().outcome else {
            return XCTFail("мусорный адрес не должен считаться разрешённым результатом")
        }
        let confirmCalls = await fetcher.count("freeipapi")
        XCTAssertEqual(confirmCalls, 0)
    }

    func test_ipv6_address_from_ipinfo_is_accepted() async {
        let fetcher = FakeFetcher(responses: [
            "ipinfo.io": .success(ipinfoData(ip: "2606:2040::1", country: "KZ")),
            "freeipapi": .success(Data(#"{"ipVersion":6,"ipAddress":"2606:2040::1","countryCode":"KZ"}"#.utf8)),
        ])
        let probe = GeoProbe(fetcher: fetcher, token: { "t" })

        guard case .resolved(let reading) = await probe.probe().outcome else {
            return XCTFail("ожидался .resolved")
        }
        XCTAssertEqual(reading.ip, "2606:2040::1")
        XCTAssertEqual(reading.confirmedCountry, "KZ")
    }

    func test_new_address_is_confirmed_anew() async {
        let fetcher = FakeFetcher(responses: [
            "ipinfo.io": .success(ipinfoData(ip: "203.0.113.28", country: "KZ")),
            "freeipapi": .success(freeipapiKZ),
        ])
        let probe = GeoProbe(fetcher: fetcher, token: { "t" })
        _ = await probe.probe()

        await fetcher.setResponse("ipinfo.io", .success(ipinfoData(ip: "198.51.100.231", country: "RU")))
        await fetcher.setResponse("freeipapi", .success(Data(#"{"ipVersion":4,"ipAddress":"198.51.100.231","countryCode":"RU"}"#.utf8)))

        guard case .resolved(let reading) = await probe.probe().outcome else {
            return XCTFail("ожидался .resolved")
        }
        XCTAssertEqual(reading.confirmedCountry, "RU")
        let confirmCalls = await fetcher.count("freeipapi")
        XCTAssertEqual(confirmCalls, 2)
    }
}
