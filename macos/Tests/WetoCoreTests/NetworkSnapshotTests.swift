import XCTest
@testable import WetoCore

/// Отпечаток снимка отвечает на один вопрос: мог ли прежний сетевой вердикт
/// устареть. Всё, что на вердикт не влияет, в него попадать не должно —
/// иначе чужой туннель стоит пользователю целей.
final class NetworkSnapshotTests: XCTestCase {

    private func snapshot(interface: String?, address: String = "198.18.0.1") -> NetworkSnapshot {
        NetworkSnapshot(outgoing: interface.map { OutgoingRoute(interface: $0, address: address) })
    }

    /// Второй VPN, живущий рядом, рвёт связь и поднимается сам. Пока он не забирает
    /// трафик, вердикт остаётся в силе: в отпечатке нет ни состава интерфейсов,
    /// ни чужих туннелей.
    func test_a_foreign_tunnel_coming_and_going_leaves_the_fingerprint_alone() {
        XCTAssertEqual(
            snapshot(interface: "utun7").verdictFingerprint,
            snapshot(interface: "utun7").verdictFingerprint
        )
    }

    func test_the_traffic_moving_to_another_interface_changes_the_fingerprint() {
        XCTAssertNotEqual(
            snapshot(interface: "utun7").verdictFingerprint,
            snapshot(interface: "en0", address: "192.168.0.100").verdictFingerprint
        )
    }

    /// Туннель умеет переподключиться, сохранив имя интерфейса, и получить другой
    /// адрес. Для вердикта это смена состояния сети, и отпечаток обязан её видеть.
    func test_the_same_interface_with_a_new_address_changes_the_fingerprint() {
        XCTAssertNotEqual(
            snapshot(interface: "utun7", address: "198.18.0.1").verdictFingerprint,
            snapshot(interface: "utun7", address: "10.7.0.2").verdictFingerprint
        )
    }

    /// Наружу никто не выпускает — вердикта быть не может, и это состояние
    /// обязано отличаться от любого рабочего.
    func test_no_outgoing_route_is_its_own_state() {
        let nothing = snapshot(interface: nil)

        XCTAssertEqual(nothing.verdictFingerprint, "out=-")
        XCTAssertNotEqual(
            nothing.verdictFingerprint,
            snapshot(interface: "utun7").verdictFingerprint
        )
    }
}
