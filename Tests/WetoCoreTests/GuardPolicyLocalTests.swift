import XCTest
@testable import WetoCore

final class GuardPolicyLocalTests: XCTestCase {

    private func config(
        vpn: String? = "Happ",
        targets: [String] = ["com.example.target"]
    ) -> GuardConfig {
        GuardConfig(
            vpnServiceName: vpn,
            blockedCountries: ["RU"],
            blockedIPRanges: [],
            targets: targets
        )
    }

    private func fullSignals(vpn: VPNStatus, config configuration: GuardConfig) -> GuardSignals {
        GuardSignals(
            isEnabled: true,
            vpn: vpn,
            geo: .resolved(GeoReading(
                ip: "203.0.113.28", asn: "AS49791",
                primaryCountry: "KZ", confirmedCountry: "KZ", confirmSource: .ipwhois
            )),
            config: configuration
        )
    }

    func test_local_decision_is_nil_when_network_verdict_is_required() {
        XCTAssertNil(GuardPolicy.decideLocal(
            isEnabled: true, vpn: .up(isPrimary: true), config: config()
        ))
    }

    func test_local_decision_short_circuits_when_guard_is_disabled() {
        XCTAssertEqual(
            GuardPolicy.decideLocal(isEnabled: false, vpn: .down, config: config()),
            .safe
        )
    }

    func test_local_decision_short_circuits_when_no_targets() {
        XCTAssertEqual(
            GuardPolicy.decideLocal(isEnabled: true, vpn: .down, config: config(targets: [])),
            .safe
        )
    }

    func test_local_decision_kills_on_vpn_down_without_touching_network() {
        XCTAssertEqual(
            GuardPolicy.decideLocal(isEnabled: true, vpn: .down, config: config()),
            .kill(.vpnDown)
        )
    }

    func test_local_decision_kills_when_vpn_is_not_primary() {
        XCTAssertEqual(
            GuardPolicy.decideLocal(isEnabled: true, vpn: .up(isPrimary: false), config: config()),
            .kill(.vpnNotPrimary)
        )
    }

    func test_local_decision_kills_when_vpn_service_is_not_chosen() {
        XCTAssertEqual(
            GuardPolicy.decideLocal(isEnabled: true, vpn: .notConfigured, config: config(vpn: nil)),
            .kill(.vpnNotConfigured)
        )
    }

    func test_local_and_full_decisions_agree_on_local_reasons() {

        let cases: [(VPNStatus, GuardConfig)] = [
            (.down, config()),
            (.up(isPrimary: false), config()),
            (.notConfigured, config(vpn: nil)),
            (.up(isPrimary: true), config(targets: [])),
        ]
        for (vpn, configuration) in cases {
            guard let local = GuardPolicy.decideLocal(
                isEnabled: true, vpn: vpn, config: configuration
            ) else { continue }
            XCTAssertEqual(
                local,
                GuardPolicy.decide(fullSignals(vpn: vpn, config: configuration)),
                "расхождение для vpn=\(vpn)"
            )
        }
    }
}
