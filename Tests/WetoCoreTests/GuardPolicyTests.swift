import XCTest
@testable import WetoCore

final class GuardPolicyTests: XCTestCase {

    private func config(
        vpn: String? = "Happ",
        blocked: Set<String> = ["RU"],
        ranges: [IPRange] = [],
        targets: [String] = ["com.example.target"]
    ) -> GuardConfig {
        GuardConfig(
            vpnServiceName: vpn,
            blockedCountries: blocked,
            blockedIPRanges: ranges,
            targets: targets
        )
    }

    private func geo(
        ip: String = "203.0.113.28",
        primary: String = "KZ",
        confirmed: String? = "KZ",
        source: ConfirmSource? = .ipwhois
    ) -> GeoOutcome {
        .resolved(GeoReading(
            ip: ip,
            asn: "AS49791",
            primaryCountry: primary,
            confirmedCountry: confirmed,
            confirmSource: source
        ))
    }

    private func signals(
        enabled: Bool = true,
        vpn: VPNStatus = .up(isPrimary: true),
        geo geoOutcome: GeoOutcome? = nil,
        config configuration: GuardConfig? = nil
    ) -> GuardSignals {
        GuardSignals(
            isEnabled: enabled,
            vpn: vpn,
            geo: geoOutcome ?? geo(),
            config: configuration ?? config()
        )
    }

    func test_everything_aligned_is_safe() {
        XCTAssertEqual(GuardPolicy.decide(signals()), .safe)
    }

    func test_disabled_guard_is_always_safe_even_with_blocked_country() {
        let s = signals(enabled: false, vpn: .down, geo: geo(primary: "RU", confirmed: "RU"))
        XCTAssertEqual(GuardPolicy.decide(s), .safe)
    }

    func test_empty_target_list_is_safe() {
        let s = signals(vpn: .down, config: config(targets: []))
        XCTAssertEqual(GuardPolicy.decide(s), .safe)
    }

    func test_vpn_not_configured_kills() {
        let s = signals(config: config(vpn: nil))
        XCTAssertEqual(GuardPolicy.decide(s), .kill(.vpnNotConfigured))
    }

    func test_vpn_down_kills() {
        XCTAssertEqual(GuardPolicy.decide(signals(vpn: .down)), .kill(.vpnDown))
    }

    func test_vpn_up_but_not_primary_kills() {
        let s = signals(vpn: .up(isPrimary: false))
        XCTAssertEqual(GuardPolicy.decide(s), .kill(.vpnNotPrimary))
    }

    func test_vpn_check_precedes_geo_check() {

        let s = signals(vpn: .down, geo: .unavailable("timeout"))
        XCTAssertEqual(GuardPolicy.decide(s), .kill(.vpnDown))
    }

    func test_geo_unavailable_kills_with_reason_text() {
        let s = signals(geo: .unavailable("timeout"))
        XCTAssertEqual(GuardPolicy.decide(s), .kill(.geoUnavailable("timeout")))
    }

    func test_blacklisted_ip_kills_even_when_country_is_allowed() {
        let s = signals(
            geo: geo(ip: "198.51.100.231", primary: "KZ", confirmed: "KZ"),
            config: config(ranges: [IPRange("198.51.100.0/22")!])
        )
        XCTAssertEqual(GuardPolicy.decide(s), .kill(.blacklistedIP("198.51.100.231")))
    }

    func test_blacklist_precedes_country_check() {

        let s = signals(
            geo: geo(ip: "198.51.100.231", primary: "RU", confirmed: "RU"),
            config: config(ranges: [IPRange("198.51.100.231")!])
        )
        XCTAssertEqual(GuardPolicy.decide(s), .kill(.blacklistedIP("198.51.100.231")))
    }

    func test_ip_outside_all_ranges_does_not_trigger_blacklist() {
        let s = signals(config: config(ranges: [IPRange("10.0.0.0/8")!]))
        XCTAssertEqual(GuardPolicy.decide(s), .safe)
    }

    func test_blocked_primary_country_kills() {
        let s = signals(geo: geo(primary: "RU", confirmed: "RU"))
        XCTAssertEqual(
            GuardPolicy.decide(s),
            .kill(.blockedCountry(code: "RU", source: "ipinfo"))
        )
    }

    func test_blocked_confirmed_country_kills_even_when_primary_is_allowed() {
        let s = signals(geo: geo(primary: "KZ", confirmed: "RU", source: .ipwhois))
        XCTAssertEqual(
            GuardPolicy.decide(s),
            .kill(.blockedCountry(code: "RU", source: "ipwhois"))
        )
    }

    func test_country_comparison_is_case_insensitive() {
        let s = signals(
            geo: geo(primary: "ru", confirmed: "ru"),
            config: config(blocked: ["RU"])
        )
        XCTAssertEqual(
            GuardPolicy.decide(s),
            .kill(.blockedCountry(code: "RU", source: "ipinfo"))
        )
    }

    func test_missing_confirmation_kills_even_when_ipinfo_says_allowed_country() {

        let s = signals(geo: geo(primary: "KZ", confirmed: nil, source: nil))
        XCTAssertEqual(GuardPolicy.decide(s), .kill(.confirmationUnavailable))
    }

    func test_blocked_primary_country_precedes_missing_confirmation() {
        let s = signals(geo: geo(primary: "RU", confirmed: nil, source: nil))
        XCTAssertEqual(
            GuardPolicy.decide(s),
            .kill(.blockedCountry(code: "RU", source: "ipinfo"))
        )
    }

    func test_country_conflict_kills() {
        let s = signals(geo: geo(primary: "KZ", confirmed: "DE"))
        XCTAssertEqual(
            GuardPolicy.decide(s),
            .kill(.countryConflict(primary: "KZ", confirmed: "DE"))
        )
    }

    func test_matching_countries_in_different_case_are_not_a_conflict() {
        let s = signals(geo: geo(primary: "KZ", confirmed: "kz"))
        XCTAssertEqual(GuardPolicy.decide(s), .safe)
    }
}
