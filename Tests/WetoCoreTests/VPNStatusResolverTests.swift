import XCTest
@testable import WetoCore

final class VPNStatusResolverTests: XCTestCase {

    private let snapshot = NetworkSnapshot(
        services: [
            .init(uuid: "108E2488", name: "Wi-Fi", activeInterface: "en0", isVPN: false),
            .init(uuid: "BC2D1D42", name: "Happ", activeInterface: "utun6", isVPN: true),
            .init(uuid: "F8D44BFF", name: "Tailscale", activeInterface: "utun7", isVPN: true),
            .init(uuid: "AC98ABFF", name: "KARO", activeInterface: nil, isVPN: true),
            .init(uuid: "9BA5C511", name: "iPhone", activeInterface: nil, isVPN: false),
            .init(uuid: "13102BC0", name: "Thunderbolt Bridge", activeInterface: nil, isVPN: false),
        ],
        primaryServiceUUID: "BC2D1D42"
    )

    private var duplicateNameSnapshot: NetworkSnapshot {
        NetworkSnapshot(
            services: [
                .init(uuid: "vpn-a", name: "Happ", activeInterface: nil, isVPN: true),
                .init(uuid: "vpn-b", name: "Happ", activeInterface: "utun6", isVPN: true),
            ],
            primaryServiceUUID: "vpn-b"
        )
    }

    func test_nil_id_is_not_configured() {
        XCTAssertEqual(VPNStatusResolver.status(serviceID: nil, in: snapshot), .notConfigured)
    }

    func test_unknown_service_id_is_down() {

        XCTAssertEqual(VPNStatusResolver.status(serviceID: "GHOST", in: snapshot), .down)
    }

    func test_non_vpn_service_is_down_even_while_it_holds_the_route() {

        let wifiPrimary = NetworkSnapshot(
            services: snapshot.services,
            primaryServiceUUID: "108E2488"
        )
        XCTAssertEqual(VPNStatusResolver.status(serviceID: "108E2488", in: wifiPrimary), .down)
    }

    func test_configured_but_not_active_service_is_down() {
        XCTAssertEqual(VPNStatusResolver.status(serviceID: "AC98ABFF", in: snapshot), .down)
    }

    func test_active_service_holding_default_route_is_up_and_primary() {
        XCTAssertEqual(
            VPNStatusResolver.status(serviceID: "BC2D1D42", in: snapshot),
            .up(isPrimary: true)
        )
    }

    func test_active_service_not_holding_default_route_is_up_but_not_primary() {

        XCTAssertEqual(
            VPNStatusResolver.status(serviceID: "F8D44BFF", in: snapshot),
            .up(isPrimary: false)
        )
    }

    func test_no_primary_service_means_not_primary() {
        let orphan = NetworkSnapshot(services: snapshot.services, primaryServiceUUID: nil)
        XCTAssertEqual(
            VPNStatusResolver.status(serviceID: "BC2D1D42", in: orphan),
            .up(isPrimary: false)
        )
    }

    func test_wifi_is_not_a_vpn_candidate() {
        XCTAssertEqual(
            snapshot.vpnCandidates.map(\.uuid),
            ["BC2D1D42", "AC98ABFF", "F8D44BFF"]
        )
    }

    func test_candidates_are_sorted_by_name_case_insensitively() {
        XCTAssertEqual(snapshot.vpnCandidates.map(\.name), ["Happ", "KARO", "Tailscale"])
    }

    func test_same_names_are_unambiguous_when_vpn_uuid_is_stored() {
        XCTAssertEqual(
            VPNStatusResolver.status(serviceID: "vpn-b", in: duplicateNameSnapshot),
            .up(isPrimary: true)
        )
        XCTAssertEqual(
            VPNStatusResolver.status(serviceID: "vpn-a", in: duplicateNameSnapshot),
            .down
        )
    }

    func test_services_sharing_a_name_stay_separate_candidates() {

        XCTAssertEqual(duplicateNameSnapshot.vpnCandidates.map(\.uuid), ["vpn-a", "vpn-b"])
    }
}
