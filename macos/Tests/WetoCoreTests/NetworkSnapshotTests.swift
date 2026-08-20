import XCTest
@testable import WetoCore

/// Отпечаток снимка отвечает на один вопрос: мог ли прежний сетевой вердикт
/// устареть. Всё, что на вердикт не влияет, в него попадать не должно —
/// иначе чужой туннель стоит пользователю целей.
final class NetworkSnapshotTests: XCTestCase {

    private let happ = NetworkServiceSnapshot(
        uuid: "HAPP", name: "Happ", activeInterface: "utun7", isVPN: true
    )
    private let wifi = NetworkServiceSnapshot(
        uuid: "WIFI", name: "Wi-Fi", activeInterface: "en0", isVPN: false
    )

    private func snapshot(
        _ services: [NetworkServiceSnapshot],
        primary: String? = "HAPP",
        iface: String? = "utun7",
        address: String = "198.18.0.1"
    ) -> NetworkSnapshot {
        NetworkSnapshot(
            services: services,
            primaryServiceUUID: primary,
            outgoing: iface.map { OutgoingRoute(interface: $0, address: address) }
        )
    }

    func test_a_foreign_tunnel_coming_and_going_leaves_the_fingerprint_alone() {
        let alone = snapshot([wifi, happ])
        let withCisco = snapshot([wifi, happ, .fromInterface("utun8")])

        XCTAssertEqual(
            alone.verdictFingerprint(forService: "HAPP"),
            withCisco.verdictFingerprint(forService: "HAPP"),
            "второй VPN не меняет ни выбранный туннель, ни выход в сеть"
        )
    }

    func test_the_selected_tunnel_moving_to_another_interface_changes_the_fingerprint() {
        let before = snapshot([wifi, happ])
        let after = snapshot(
            [wifi, .init(uuid: "HAPP", name: "Happ", activeInterface: "utun9", isVPN: true)],
            iface: "utun9"
        )

        XCTAssertNotEqual(
            before.verdictFingerprint(forService: "HAPP"),
            after.verdictFingerprint(forService: "HAPP")
        )
    }

    func test_the_route_owner_changing_changes_the_fingerprint() {
        let throughTunnel = snapshot([wifi, happ])
        let throughWiFi = snapshot([wifi, happ], primary: "WIFI", iface: "en0")

        XCTAssertNotEqual(
            throughTunnel.verdictFingerprint(forService: "HAPP"),
            throughWiFi.verdictFingerprint(forService: "HAPP")
        )
    }

    func test_the_selected_service_disappearing_changes_the_fingerprint() {
        let present = snapshot([wifi, happ])
        let gone = snapshot([wifi], primary: "WIFI", iface: "en0")

        XCTAssertNotEqual(
            present.verdictFingerprint(forService: "HAPP"),
            gone.verdictFingerprint(forService: "HAPP")
        )
    }

    /// Пропавший сервис и невыбранный VPN — разные состояния: у первого впереди
    /// `vpnDown`, у второго `vpnNotConfigured`, и путать их вердикты нельзя.
    func test_a_missing_service_is_not_the_same_as_no_selection() {
        let gone = snapshot([wifi], primary: "WIFI", iface: "en0")

        XCTAssertNotEqual(
            gone.verdictFingerprint(forService: "HAPP"),
            gone.verdictFingerprint(forService: nil)
        )
    }
}
