import XCTest
@testable import WetoCore

final class TunnelInterfaceTests: XCTestCase {

    private func interface(_ name: String, up: Bool = true, ipv4: Bool = true) -> InterfaceSnapshot {
        InterfaceSnapshot(name: name, isUp: up, hasIPv4: ipv4)
    }

    func test_a_running_tunnel_with_an_address_qualifies() {
        XCTAssertTrue(TunnelInterface.qualifies(interface("utun4")))
        XCTAssertTrue(TunnelInterface.qualifies(interface("ppp0")))
        XCTAssertTrue(TunnelInterface.qualifies(interface("ipsec0")))
    }

    /// macOS держит несколько служебных `utun` постоянно — частный узел iCloud,
    /// AirDrop. Адреса IPv4 у них нет, и в списке выбора им делать нечего:
    /// пользователь их не поднимал и опознать не может.
    func test_a_system_tunnel_without_an_address_does_not_qualify() {
        XCTAssertFalse(TunnelInterface.qualifies(interface("utun0", ipv4: false)))
    }

    func test_a_downed_tunnel_does_not_qualify() {
        XCTAssertFalse(TunnelInterface.qualifies(interface("utun4", up: false)))
    }

    /// Обычная сетевая карта туннелем не становится ни при каких адресах:
    /// иначе Wi-Fi попал бы в список VPN.
    func test_ordinary_interfaces_never_qualify() {
        for name in ["en0", "en1", "lo0", "bridge0", "awdl0"] {
            XCTAssertFalse(TunnelInterface.qualifies(interface(name)), name)
        }
    }
}
