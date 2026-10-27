import XCTest
@testable import WetoCore

/// Статус туннеля — чистая функция имени и снимка сети. Политика по нему завершает
/// цели без сети, поэтому ошибка здесь стоила бы либо целей при исправном туннеле,
/// либо охраны при упавшем.
final class VPNTunnelStatusTests: XCTestCase {

    private func snapshot(outgoing interface: String?, up: [String]) -> NetworkSnapshot {
        NetworkSnapshot(
            outgoing: interface.map { OutgoingRoute(interface: $0, address: "10.8.0.2") },
            upInterfaces: up
        )
    }

    func test_without_a_chosen_tunnel_there_is_nothing_to_report() {
        XCTAssertEqual(VPNTunnelStatus(chosen: nil, snapshot: snapshot(outgoing: "en0", up: ["en0"])), .notChosen)
    }

    func test_a_tunnel_missing_from_the_raised_interfaces_is_down() {
        XCTAssertEqual(VPNTunnelStatus(chosen: "wg0", snapshot: snapshot(outgoing: "en0", up: ["en0", "lo0"])), .down)
    }

    /// Носитель трафика сам по себе не доказывает, что интерфейс поднят: «поднят»
    /// решает только список поднятых.
    func test_the_carrier_alone_does_not_make_a_tunnel_raised() {
        XCTAssertEqual(VPNTunnelStatus(chosen: "wg0", snapshot: snapshot(outgoing: "wg0", up: [])), .down)
    }

    func test_a_raised_tunnel_the_traffic_goes_around_is_bypassed() {
        XCTAssertEqual(
            VPNTunnelStatus(chosen: "wg0", snapshot: snapshot(outgoing: "eth0", up: ["eth0", "wg0"])),
            .bypassed(via: "eth0")
        )
    }

    func test_a_raised_tunnel_carrying_the_traffic_is_carrying() {
        XCTAssertEqual(
            VPNTunnelStatus(chosen: "wg0", snapshot: snapshot(outgoing: "wg0", up: ["eth0", "wg0"])),
            .carrying
        )
    }

    /// Наружу не выпускает никто — улики против туннеля нет, отвечает гео.
    func test_no_outgoing_route_leaves_the_answer_to_geo() {
        XCTAssertEqual(VPNTunnelStatus(chosen: "wg0", snapshot: snapshot(outgoing: nil, up: ["wg0"])), .carrying)
    }

    /// Список поднятых интерфейсов меняется вместе со вторым VPN, а выход — нет.
    func test_raised_interfaces_stay_out_of_the_fingerprint() {
        XCTAssertEqual(
            snapshot(outgoing: "utun6", up: ["en0", "utun6"]).verdictFingerprint,
            snapshot(outgoing: "utun6", up: ["en0", "utun6", "utun7"]).verdictFingerprint
        )
    }

    func test_tunnel_evidence_is_local_like_the_closed_app() {
        XCTAssertTrue(UnsafeEvidence.vpnAppNotRunning.isLocal)
        XCTAssertTrue(UnsafeEvidence.vpnTunnelDown("wg0").isLocal)
        XCTAssertTrue(UnsafeEvidence.trafficBypassesTunnel(tunnel: "wg0", via: "eth0").isLocal)
        XCTAssertFalse(UnsafeEvidence.blockedCountry(code: "RU", source: "ipinfo").isLocal)
        XCTAssertFalse(UnsafeEvidence.pauseExpired(ceiling: 60).isLocal)
    }

    func test_tunnel_evidence_names_the_tunnel_and_the_carrier() {
        XCTAssertEqual(UnsafeEvidence.vpnTunnelDown("wg0").displayText, "VPN-туннель wg0 не поднят")
        XCTAssertEqual(
            UnsafeEvidence.trafficBypassesTunnel(tunnel: "wg0", via: "eth0").displayText,
            "трафик идёт мимо туннеля wg0 — через eth0"
        )
    }

    /// Проверка приложения идёт раньше туннеля: оба выбраны быть не могут, но если
    /// настройки разошлись, первой называется та же улика, что и раньше.
    func test_the_app_is_asked_before_the_tunnel() {
        let config = GuardConfig(vpnAppRule: "su.ffg.happ", blockedCountries: [], blockedIPRanges: [],
                                 allowedCountries: [], allowedIPRanges: [], targets: ["nano"], vpnTunnel: "wg0")
        XCTAssertEqual(
            GuardPolicy.decideLocal(isEnabled: true, vpn: .notRunning, tunnel: .down, config: config),
            .kill(.vpnAppNotRunning)
        )
        XCTAssertEqual(
            GuardPolicy.decideLocal(isEnabled: true, vpn: .running, tunnel: .down, config: config),
            .kill(.vpnTunnelDown("wg0"))
        )
    }
}
