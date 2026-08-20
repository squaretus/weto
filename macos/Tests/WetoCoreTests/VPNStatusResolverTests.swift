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
        primaryServiceUUID: "BC2D1D42",
        outgoing: OutgoingRoute(interface: "utun6", address: "198.18.0.1")
    )

    private var duplicateNameSnapshot: NetworkSnapshot {
        NetworkSnapshot(
            services: [
                .init(uuid: "vpn-a", name: "Happ", activeInterface: nil, isVPN: true),
                .init(uuid: "vpn-b", name: "Happ", activeInterface: "utun6", isVPN: true),
            ],
            primaryServiceUUID: "vpn-b",
            outgoing: OutgoingRoute(interface: "utun6", address: "198.18.0.1")
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

    /// Наружу никто не выпускает — значит и туннель трафика не несёт.
    /// Это `up(isPrimary: false)`: интерфейс есть, а трафика через него нет.
    func test_without_an_outgoing_route_nothing_is_primary() {
        let orphan = NetworkSnapshot(
            services: snapshot.services,
            primaryServiceUUID: "BC2D1D42",
            outgoing: nil
        )
        XCTAssertEqual(
            VPNStatusResolver.status(serviceID: "BC2D1D42", in: orphan),
            .up(isPrimary: false)
        )
    }

    /// `PrimaryService` из конфигурации сети на вердикт больше не влияет:
    /// у туннеля мимо NetworkExtension сервиса нет вовсе, а спрашивать надо ядро.
    func test_the_configured_primary_service_does_not_decide() {
        let wifiIsPrimaryService = NetworkSnapshot(
            services: snapshot.services,
            primaryServiceUUID: "108E2488",
            outgoing: OutgoingRoute(interface: "utun6", address: "198.18.0.1")
        )
        XCTAssertEqual(
            VPNStatusResolver.status(serviceID: "BC2D1D42", in: wifiIsPrimaryService),
            .up(isPrimary: true)
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

    // MARK: - Туннель без сервиса

    /// Клиент, поднявший `utun` сам, сетевого сервиса не создаёт. Раньше такой
    /// туннель было невозможно ни выбрать, ни опознать — сборка из GitHub
    /// не появлялась в списке, в отличие от сборки из App Store.
    func test_interface_backed_candidate_holding_the_route_is_up_and_primary() {
        let snapshot = NetworkSnapshot(
            services: [
                .init(uuid: "108E2488", name: "Wi-Fi", activeInterface: "en0", isVPN: false),
                .fromInterface("utun4"),
            ],
            // Сервисом остаётся Wi-Fi: у туннеля сервиса нет вовсе, и ядро —
            // единственный, кто знает, что трафик уходит в туннель.
            primaryServiceUUID: "108E2488",
            outgoing: OutgoingRoute(interface: "utun4", address: "172.18.0.1")
        )

        XCTAssertEqual(
            VPNStatusResolver.status(serviceID: "interface:utun4", in: snapshot),
            .up(isPrimary: true)
        )
    }

    /// Туннель поднят, но маршрут по умолчанию всё ещё у Wi-Fi: это «поднят,
    /// но трафик идёт мимо», и цели обязаны завершаться.
    func test_interface_backed_candidate_without_the_route_is_up_but_not_primary() {
        let snapshot = NetworkSnapshot(
            services: [.fromInterface("utun4")],
            primaryServiceUUID: "108E2488",
            outgoing: OutgoingRoute(interface: "en0", address: "192.168.0.100")
        )

        XCTAssertEqual(
            VPNStatusResolver.status(serviceID: "interface:utun4", in: snapshot),
            .up(isPrimary: false)
        )
    }

    /// Имена `utun` не закреплены за приложением и меняются между запусками.
    /// Исчезнувший интерфейс — это `down`, то есть fail-closed, а не «наверное,
    /// это вон тот другой туннель».
    func test_a_vanished_interface_is_down_not_guessed() {
        let snapshot = NetworkSnapshot(
            services: [.fromInterface("utun5")],
            primaryServiceUUID: nil,
            outgoing: OutgoingRoute(interface: "utun5", address: "172.18.0.1")
        )

        XCTAssertEqual(VPNStatusResolver.status(serviceID: "interface:utun4", in: snapshot), .down)
    }

    /// Сервис, чей интерфейс выпускает трафик, считается основным, даже когда
    /// `PrimaryService` называет другой: у туннелей поверх сервиса так бывает.
    func test_a_service_whose_interface_holds_the_route_is_primary() {
        let snapshot = NetworkSnapshot(
            services: [.init(uuid: "BC2D1D42", name: "Happ", activeInterface: "utun6", isVPN: true)],
            primaryServiceUUID: "108E2488",
            outgoing: OutgoingRoute(interface: "utun6", address: "198.18.0.1")
        )

        XCTAssertEqual(
            VPNStatusResolver.status(serviceID: "BC2D1D42", in: snapshot),
            .up(isPrimary: true)
        )
    }

    func test_interface_backed_candidates_are_told_apart_from_services() {
        XCTAssertTrue(NetworkServiceSnapshot.fromInterface("utun4").isInterfaceBacked)
        XCTAssertFalse(
            NetworkServiceSnapshot(uuid: "BC2D1D42", name: "Happ", activeInterface: "utun6", isVPN: true)
                .isInterfaceBacked
        )
    }
}
