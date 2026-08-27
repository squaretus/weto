import XCTest
@testable import WetoCore

final class GuardPolicyLocalTests: XCTestCase {

    private func config(
        vpn: String? = "Happ",
        targets: [String] = ["com.example.target"]
    ) -> GuardConfig {
        GuardConfig(
            vpnAppRule: vpn,
            blockedCountries: ["RU"],
            blockedIPRanges: [],
            allowedCountries: [],
            allowedIPRanges: [],
            targets: targets
        )
    }

    private func fullSignals(vpn: VPNAppStatus, config configuration: GuardConfig) -> GuardSignals {
        GuardSignals(
            isEnabled: true,
            vpn: vpn,
            geo: .resolved(GeoReading(
                ip: "203.0.113.28", primaryCountry: "KZ", confirmedCountry: "KZ", confirmSource: .freeipapi
            )),
            config: configuration
        )
    }

    func test_local_decision_is_nil_when_network_verdict_is_required() {
        XCTAssertNil(GuardPolicy.decideLocal(
            isEnabled: true, vpn: .running, config: config()
        ))
    }

    func test_local_decision_short_circuits_when_guard_is_disabled() {
        XCTAssertEqual(
            GuardPolicy.decideLocal(isEnabled: false, vpn: .notRunning, config: config()),
            .safe
        )
    }

    func test_local_decision_short_circuits_when_no_targets() {
        XCTAssertEqual(
            GuardPolicy.decideLocal(isEnabled: true, vpn: .notRunning, config: config(targets: [])),
            .safe
        )
    }

    func test_local_decision_kills_when_the_vpn_app_is_not_running() {
        XCTAssertEqual(
            GuardPolicy.decideLocal(isEnabled: true, vpn: .notRunning, config: config()),
            .kill(.vpnAppNotRunning)
        )
    }

    func test_local_decision_kills_when_the_vpn_app_is_not_chosen() {
        XCTAssertEqual(
            GuardPolicy.decideLocal(isEnabled: true, vpn: .notChosen, config: config(vpn: nil)),
            .kill(.vpnAppNotChosen)
        )
    }

    func test_local_and_full_decisions_agree_on_local_reasons() {

        let cases: [(VPNAppStatus, GuardConfig)] = [
            (.notRunning, config()),
            (.notChosen, config(vpn: nil)),
            (.running, config(targets: [])),
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
