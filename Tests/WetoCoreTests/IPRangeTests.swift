import XCTest
@testable import WetoCore

final class IPRangeTests: XCTestCase {

    func test_bare_ipv4_matches_only_itself() {
        let range = IPRange("203.0.113.28")
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.prefixLength, 32)
        XCTAssertTrue(range!.contains("203.0.113.28"))
        XCTAssertFalse(range!.contains("203.0.113.29"))
    }

    func test_ipv4_prefix_matches_whole_subnet() {
        let range = IPRange("10.0.0.0/8")!
        XCTAssertTrue(range.contains("10.0.0.1"))
        XCTAssertTrue(range.contains("10.255.255.255"))
        XCTAssertFalse(range.contains("11.0.0.1"))
        XCTAssertFalse(range.contains("9.255.255.255"))
    }

    func test_non_byte_aligned_prefix_is_respected() {
        let range = IPRange("192.168.0.0/20")!
        XCTAssertTrue(range.contains("192.168.15.255"))
        XCTAssertFalse(range.contains("192.168.16.0"))
    }

    func test_zero_prefix_matches_every_address_of_same_family() {
        let range = IPRange("0.0.0.0/0")!
        XCTAssertTrue(range.contains("1.2.3.4"))
        XCTAssertTrue(range.contains("255.255.255.255"))
        XCTAssertFalse(range.contains("2606:2040::1"))
    }

    func test_host_bits_outside_prefix_are_ignored() {
        // 10.5.5.5/8 и 10.0.0.0/8 — одна и та же сеть.
        XCTAssertEqual(IPRange("10.5.5.5/8")?.networkBytes, IPRange("10.0.0.0/8")?.networkBytes)
        XCTAssertEqual(IPRange("10.5.5.5/8")?.prefixLength, IPRange("10.0.0.0/8")?.prefixLength)
    }

    func test_ipv6_prefix_matches_subnet() {
        let range = IPRange("2606:2040::/32")!
        XCTAssertTrue(range.isIPv6)
        XCTAssertTrue(range.contains("2606:2040:2800:141::2"))
        XCTAssertFalse(range.contains("2607:2040::1"))
    }

    func test_families_never_match_each_other() {
        XCTAssertFalse(IPRange("10.0.0.0/8")!.contains("2606:2040::1"))
        XCTAssertFalse(IPRange("2606:2040::/32")!.contains("10.0.0.1"))
    }

    func test_malformed_input_returns_nil() {
        XCTAssertNil(IPRange(""))
        XCTAssertNil(IPRange("   "))
        XCTAssertNil(IPRange("не адрес"))
        XCTAssertNil(IPRange("10.0.0.0/33"))
        XCTAssertNil(IPRange("10.0.0.0/-1"))
        XCTAssertNil(IPRange("2606:2040::/129"))
        XCTAssertNil(IPRange("10.0.0.0/8/8"))
        XCTAssertNil(IPRange("999.0.0.1"))
    }

    func test_contains_rejects_malformed_candidate() {
        XCTAssertFalse(IPRange("10.0.0.0/8")!.contains("не адрес"))
    }

    func test_original_text_is_preserved_for_display() {
        XCTAssertEqual(IPRange("  10.5.5.5/8  ")?.text, "10.5.5.5/8")
    }
}
