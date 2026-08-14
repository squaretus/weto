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

    func data(from url: URL, headers: [String: String]) async throws -> Data {
        let key = responses.keys.first { url.absoluteString.contains($0) } ?? "unmatched"
        callCounts[key, default: 0] += 1
        guard let result = responses[key] else { throw FetchFailure() }
        return try result.get()
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
            "freeipapi": .failure(HTTPFetchError.badStatus(429)),
            "geojs.io": .failure(HTTPFetchError.badStatus(503)),
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

    func test_reference_source_failure_is_shown_instead_of_a_country() async {
        let fetcher = FakeFetcher(responses: ["geojs.io": .failure(HTTPFetchError.badStatus(503))])
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

    func test_confirmation_is_requested_on_every_probe() async {

        let fetcher = FakeFetcher(responses: [
            "ipinfo.io": .success(ipinfoData(ip: "203.0.113.28", country: "KZ")),
            "freeipapi": .success(freeipapiKZ),
        ])
        let probe = GeoProbe(fetcher: fetcher, token: { "t" })

        for _ in 0..<5 { _ = await probe.probe() }

        let ipinfoCalls = await fetcher.count("ipinfo.io")
        let confirmCalls = await fetcher.count("freeipapi")
        XCTAssertEqual(ipinfoCalls, 5, "ipinfo опрашивается каждый такт")
        XCTAssertEqual(
            confirmCalls, 5,
            "подтверждение не кэшируется: иначе смена страны на том же адресе осталась бы незамеченной"
        )
    }

    func test_country_change_is_seen_immediately() async {

        let fetcher = FakeFetcher(responses: [
            "ipinfo.io": .success(ipinfoData(ip: "203.0.113.28", country: "KZ")),
            "freeipapi": .success(freeipapiKZ),
        ])
        let probe = GeoProbe(fetcher: fetcher, token: { "t" })
        _ = await probe.probe()

        // Тот же адрес, но подтверждающий сервис поменял вердикт.
        await fetcher.setResponse(
            "freeipapi",
            .success(Data(#"{"ipVersion":4,"ipAddress":"203.0.113.28","countryCode":"RU"}"#.utf8))
        )

        guard case .resolved(let reading) = await probe.probe().outcome else {
            return XCTFail("ожидался .resolved")
        }
        XCTAssertEqual(reading.confirmedCountry, "RU")
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
