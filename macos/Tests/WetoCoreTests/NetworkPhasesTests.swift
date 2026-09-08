import XCTest
@testable import WetoCore

final class NetworkPhasesTests: XCTestCase {

    /// Ничего не завершилось — застряли на DNS.
    func test_stalled_on_dns_when_nothing_finished() {
        let phases = NetworkPhases(dnsMilliseconds: nil, connectMilliseconds: nil,
                                   tlsMilliseconds: nil, firstByteMilliseconds: nil)
        XCTAssertEqual(phases.stalledPhase, .dns)
    }

    func test_stalled_on_connect_after_dns() {
        let phases = NetworkPhases(dnsMilliseconds: 12, connectMilliseconds: nil,
                                   tlsMilliseconds: nil, firstByteMilliseconds: nil)
        XCTAssertEqual(phases.stalledPhase, .connect)
    }

    func test_stalled_on_tls_after_connect() {
        let phases = NetworkPhases(dnsMilliseconds: 12, connectMilliseconds: 40,
                                   tlsMilliseconds: nil, firstByteMilliseconds: nil)
        XCTAssertEqual(phases.stalledPhase, .tls)
    }

    /// Соединение и TLS готовы, ответа нет: это мёртвый сервис, а не мёртвый туннель.
    func test_stalled_waiting_for_first_byte() {
        let phases = NetworkPhases(dnsMilliseconds: 12, connectMilliseconds: 40,
                                   tlsMilliseconds: 90, firstByteMilliseconds: nil)
        XCTAssertEqual(phases.stalledPhase, .firstByte)
    }

    func test_complete_request_has_no_stalled_phase() {
        let phases = NetworkPhases(dnsMilliseconds: 12, connectMilliseconds: 40,
                                   tlsMilliseconds: 90, firstByteMilliseconds: 300)
        XCTAssertNil(phases.stalledPhase)
    }

    func test_timeout_names_the_phase_in_display_text() {
        XCTAssertEqual(GeoFailure.timedOut(nil).displayText, "таймаут запроса")
        XCTAssertEqual(GeoFailure.timedOut(.dns).displayText, "таймаут запроса (DNS)")
        XCTAssertEqual(GeoFailure.timedOut(.connect).displayText, "таймаут запроса (соединение)")
        XCTAssertEqual(GeoFailure.timedOut(.tls).displayText, "таймаут запроса (TLS)")
        XCTAssertEqual(GeoFailure.timedOut(.firstByte).displayText, "таймаут запроса (ожидание ответа)")
    }

    func test_phases_are_encoded_with_stable_keys() throws {
        let phases = NetworkPhases(dnsMilliseconds: 1, connectMilliseconds: 2,
                                   tlsMilliseconds: 3, firstByteMilliseconds: 4)
        let object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(phases)) as? [String: Any]
        XCTAssertEqual(
            Set(object?.keys.map { $0 } ?? []),
            ["dnsMilliseconds", "connectMilliseconds", "tlsMilliseconds", "firstByteMilliseconds"]
        )
    }
}
