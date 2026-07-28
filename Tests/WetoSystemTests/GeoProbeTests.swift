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

/// Управляемые часы: TTL кэша проверяется без ожидания реального времени.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)

    var now: @Sendable () -> Date {
        { [self] in
            lock.lock(); defer { lock.unlock() }
            return current
        }
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock()
    }
}

final class GeoProbeTests: XCTestCase {

    private func ipinfoData(ip: String, country: String) -> Data {
        Data("""
        {"ip":"\(ip)","asn":"AS49791","as_name":"Newserverlife LLC",
         "country_code":"\(country)","country":"Kazakhstan"}
        """.utf8)
    }

    private let ipwhoisKZ = Data(#"{"ip":"203.0.113.28","success":true,"country_code":"KZ"}"#.utf8)
    private let geojsKZ = Data(#"{"country":"KZ","country_3":"KAZ","ip":"203.0.113.28","name":"Kazakhstan"}"#.utf8)

    func test_ipinfo_failure_yields_unavailable() async {
        let fetcher = FakeFetcher(responses: ["ipinfo.io": .failure(FetchFailure())])
        let probe = GeoProbe(fetcher: fetcher, token: { "t" })

        guard case .unavailable = await probe.probe() else {
            return XCTFail("ожидался .unavailable")
        }
    }

    func test_missing_token_yields_unavailable_without_network_call() async {
        let fetcher = FakeFetcher(responses: [:])
        let probe = GeoProbe(fetcher: fetcher, token: { nil })

        guard case .unavailable = await probe.probe() else {
            return XCTFail("ожидался .unavailable")
        }
        let calls = await fetcher.count("ipinfo.io")
        XCTAssertEqual(calls, 0)
    }

    func test_successful_probe_uses_ipwhois_as_confirmation() async {
        let fetcher = FakeFetcher(responses: [
            "ipinfo.io": .success(ipinfoData(ip: "203.0.113.28", country: "KZ")),
            "ipwho.is": .success(ipwhoisKZ),
        ])
        let probe = GeoProbe(fetcher: fetcher, token: { "t" })

        guard case .resolved(let reading) = await probe.probe() else {
            return XCTFail("ожидался .resolved")
        }
        XCTAssertEqual(reading.ip, "203.0.113.28")
        XCTAssertEqual(reading.primaryCountry, "KZ")
        XCTAssertEqual(reading.confirmedCountry, "KZ")
        XCTAssertEqual(reading.confirmSource, .ipwhois)
    }

    func test_geojs_is_used_when_ipwhois_fails() async {
        let fetcher = FakeFetcher(responses: [
            "ipinfo.io": .success(ipinfoData(ip: "203.0.113.28", country: "KZ")),
            "ipwho.is": .failure(FetchFailure()),
            "geojs.io": .success(geojsKZ),
        ])
        let probe = GeoProbe(fetcher: fetcher, token: { "t" })

        guard case .resolved(let reading) = await probe.probe() else {
            return XCTFail("ожидался .resolved")
        }
        XCTAssertEqual(reading.confirmedCountry, "KZ")
        XCTAssertEqual(reading.confirmSource, .geojs)
    }

    func test_both_confirmations_failing_yields_resolved_without_confirmation() async {
        let fetcher = FakeFetcher(responses: [
            "ipinfo.io": .success(ipinfoData(ip: "203.0.113.28", country: "KZ")),
            "ipwho.is": .failure(FetchFailure()),
            "geojs.io": .failure(FetchFailure()),
        ])
        let probe = GeoProbe(fetcher: fetcher, token: { "t" })

        guard case .resolved(let reading) = await probe.probe() else {
            return XCTFail("ожидался .resolved, а не .unavailable — IP-то мы получили")
        }
        XCTAssertNil(reading.confirmedCountry)
        XCTAssertNil(reading.confirmSource)
    }

    func test_successful_confirmation_is_cached_while_ip_is_unchanged() async {
        let fetcher = FakeFetcher(responses: [
            "ipinfo.io": .success(ipinfoData(ip: "203.0.113.28", country: "KZ")),
            "ipwho.is": .success(ipwhoisKZ),
        ])
        let probe = GeoProbe(fetcher: fetcher, token: { "t" })

        for _ in 0..<5 { _ = await probe.probe() }

        let ipinfoCalls = await fetcher.count("ipinfo.io")
        let confirmCalls = await fetcher.count("ipwho.is")
        XCTAssertEqual(ipinfoCalls, 5, "ipinfo опрашивается каждый такт")
        XCTAssertEqual(confirmCalls, 1, "успешное подтверждение живёт в кэше")
    }

    func test_failed_confirmation_retries_on_same_ip_and_recovers() async {

        let fetcher = FakeFetcher(responses: [
            "ipinfo.io": .success(ipinfoData(ip: "203.0.113.28", country: "KZ")),
            "ipwho.is": .failure(FetchFailure()),
            "geojs.io": .failure(FetchFailure()),
        ])
        let probe = GeoProbe(fetcher: fetcher, token: { "t" })

        _ = await probe.probe()
        await fetcher.setResponse("ipwho.is", .success(ipwhoisKZ))

        guard case .resolved(let reading) = await probe.probe() else {
            return XCTFail("ожидался .resolved")
        }
        XCTAssertEqual(reading.confirmedCountry, "KZ", "отказ не имеет права застрять в кэше")
        let confirmCalls = await fetcher.count("ipwho.is")
        XCTAssertEqual(confirmCalls, 2)
    }

    func test_cached_confirmation_expires_after_ttl() async {
        let clock = FakeClock()
        let fetcher = FakeFetcher(responses: [
            "ipinfo.io": .success(ipinfoData(ip: "203.0.113.28", country: "KZ")),
            "ipwho.is": .success(ipwhoisKZ),
        ])
        let probe = GeoProbe(fetcher: fetcher, token: { "t" }, now: clock.now)

        _ = await probe.probe()
        clock.advance(by: Constants.geoConfirmationTTLSeconds - 1)
        _ = await probe.probe()
        let cachedCalls = await fetcher.count("ipwho.is")
        XCTAssertEqual(cachedCalls, 1, "до истечения TTL запроса быть не должно")

        clock.advance(by: 2)
        _ = await probe.probe()
        let refreshedCalls = await fetcher.count("ipwho.is")
        XCTAssertEqual(refreshedCalls, 2, "после TTL подтверждение перезапрашивается")
    }

    func test_malformed_ip_from_ipinfo_is_rejected_without_confirmation_request() async {

        let fetcher = FakeFetcher(responses: [
            "ipinfo.io": .success(ipinfoData(ip: "не адрес", country: "KZ")),
            "ipwho.is": .success(ipwhoisKZ),
        ])
        let probe = GeoProbe(fetcher: fetcher, token: { "t" })

        guard case .unavailable = await probe.probe() else {
            return XCTFail("мусорный адрес не должен считаться разрешённым результатом")
        }
        let confirmCalls = await fetcher.count("ipwho.is")
        XCTAssertEqual(confirmCalls, 0)
    }

    func test_ipv6_address_from_ipinfo_is_accepted() async {
        let fetcher = FakeFetcher(responses: [
            "ipinfo.io": .success(ipinfoData(ip: "2606:2040::1", country: "KZ")),
            "ipwho.is": .success(Data(#"{"success":true,"country_code":"KZ"}"#.utf8)),
        ])
        let probe = GeoProbe(fetcher: fetcher, token: { "t" })

        guard case .resolved(let reading) = await probe.probe() else {
            return XCTFail("ожидался .resolved")
        }
        XCTAssertEqual(reading.ip, "2606:2040::1")
        XCTAssertEqual(reading.confirmedCountry, "KZ")
    }

    func test_ip_change_invalidates_confirmation_cache() async {
        let fetcher = FakeFetcher(responses: [
            "ipinfo.io": .success(ipinfoData(ip: "203.0.113.28", country: "KZ")),
            "ipwho.is": .success(ipwhoisKZ),
        ])
        let probe = GeoProbe(fetcher: fetcher, token: { "t" })
        _ = await probe.probe()

        await fetcher.setResponse("ipinfo.io", .success(ipinfoData(ip: "198.51.100.231", country: "RU")))
        await fetcher.setResponse("ipwho.is", .success(Data(#"{"success":true,"country_code":"RU"}"#.utf8)))

        guard case .resolved(let reading) = await probe.probe() else {
            return XCTFail("ожидался .resolved")
        }
        XCTAssertEqual(reading.confirmedCountry, "RU")
        let confirmCalls = await fetcher.count("ipwho.is")
        XCTAssertEqual(confirmCalls, 2)
    }
}
