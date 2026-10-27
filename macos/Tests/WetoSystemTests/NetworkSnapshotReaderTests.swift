import XCTest
@testable import WetoSystem
import WetoCore

/// Снимок сети сведён к одному вопросу — через кого ядро выпускает вердиктный
/// запрос, — поэтому проверок здесь ровно столько же: ответ ядра и его согласие
/// с системой. Живая машина, потому что подделать таблицу маршрутов нечем.
final class NetworkSnapshotReaderTests: XCTestCase {

    /// Снимок с уже разрешённым адресом гео-сервиса.
    ///
    /// Имя разрешается в стороне от опроса — блокировать им охрану нельзя, — поэтому
    /// первый снимок после старта носителя трафика ещё не знает. Живым проверкам
    /// нужно дождаться разрешения, а не ловить эту секунду.
    private func snapshotWithRoute(within seconds: TimeInterval = 3) -> NetworkSnapshot {
        let reader = NetworkSnapshotReader()
        var snapshot = reader.snapshot()
        let deadline = Date().addingTimeInterval(seconds)

        while snapshot.outgoing == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            snapshot = reader.snapshot()
        }
        return snapshot
    }

    func test_repeated_reads_are_stable() {
        let reader = NetworkSnapshotReader()
        XCTAssertEqual(reader.snapshot(), reader.snapshot())
    }

    /// Носитель трафика в снимке — тот, чьему интерфейсу принадлежит выбранный
    /// ядром исходящий адрес. Иначе отпечаток склеивал бы разные состояния сети.
    func test_the_carrier_owns_the_outgoing_address() throws {
        let snapshot = snapshotWithRoute()
        guard let outgoing = snapshot.outgoing else {
            throw XCTSkip("наружу сейчас никто не выпускает")
        }

        let addresses = try XCTUnwrap(
            InterfaceAddresses.all()[outgoing.interface],
            "интерфейс \(outgoing.interface) не найден среди живых"
        )
        XCTAssertTrue(
            addresses.contains(outgoing.address),
            "адрес \(outgoing.address) не принадлежит \(outgoing.interface)"
        )
    }

    /// Отпечаток обязан отличать «наружу никто не выпускает» от любого рабочего
    /// состояния: в первом вердикта быть не может.
    func test_the_fingerprint_names_the_carrier() throws {
        let snapshot = snapshotWithRoute()
        guard let outgoing = snapshot.outgoing else {
            throw XCTSkip("наружу сейчас никто не выпускает")
        }

        XCTAssertTrue(snapshot.verdictFingerprint.contains(outgoing.interface))
        XCTAssertNotEqual(snapshot.verdictFingerprint, "out=-")
    }

    /// Проба подменяется — остальная сборка снимка проверяется без сети.
    func test_the_snapshot_carries_whatever_the_probe_answered() {
        let route = OutgoingRoute(interface: "utun9", address: "10.7.0.2")
        let snapshot = NetworkSnapshotReader(routeProbe: FixedRoute(route), interfaces: FixedInterfaces([])).snapshot()

        XCTAssertEqual(snapshot.outgoing, route)
        XCTAssertEqual(snapshot.verdictFingerprint, "out=utun9/10.7.0.2")
    }

    /// Поднятые интерфейсы едут в снимок для статуса туннеля, но не в отпечаток.
    func test_raised_interfaces_reach_the_snapshot_but_not_the_fingerprint() {
        let route = OutgoingRoute(interface: "utun9", address: "10.7.0.2")
        let interfaces = FixedInterfaces([
            RaisedInterface(name: "en0", addresses: ["192.168.0.100"]),
            RaisedInterface(name: "utun9", addresses: ["10.7.0.2"]),
        ])
        let snapshot = NetworkSnapshotReader(routeProbe: FixedRoute(route), interfaces: interfaces).snapshot()

        XCTAssertEqual(snapshot.upInterfaces, ["en0", "utun9"])
        XCTAssertEqual(snapshot.verdictFingerprint, "out=utun9/10.7.0.2")
    }

    /// Живая машина: носитель трафика поднят — иначе ядро не выпускало бы через него.
    func test_the_live_carrier_is_among_the_raised_interfaces() throws {
        let snapshot = snapshotWithRoute()
        guard let outgoing = snapshot.outgoing else {
            throw XCTSkip("наружу сейчас никто не выпускает")
        }
        XCTAssertTrue(snapshot.upInterfaces.contains(outgoing.interface), "\(snapshot.upInterfaces)")
        XCTAssertFalse(KernelInterfaceList().raisedInterfaces().contains { $0.name.isEmpty })
    }

    /// Живая машина: все интерфейсы — это и опущенные тоже, поэтому поднятые входят в них целиком.
    /// `weto vpn set wg0` называет туннелем и опущенный wg0.
    func test_all_interface_names_cover_the_raised_ones() {
        let all = Set(KernelInterfaceList().interfaceNames())
        let raised = Set(KernelInterfaceList().raisedInterfaces().map(\.name))
        XCTAssertTrue(all.contains("lo0"), "\(all)")
        XCTAssertTrue(raised.isSubset(of: all), "поднятые \(raised) не все среди \(all)")
    }

    func test_without_a_route_the_snapshot_is_empty() {
        let snapshot = NetworkSnapshotReader(routeProbe: FixedRoute(nil), interfaces: FixedInterfaces([])).snapshot()

        XCTAssertNil(snapshot.outgoing)
        XCTAssertEqual(snapshot.verdictFingerprint, "out=-")
    }
}

private struct FixedRoute: RouteProbing {
    let route: OutgoingRoute?

    init(_ route: OutgoingRoute?) { self.route = route }

    func outgoingRoute() -> OutgoingRoute? { route }
}

private struct FixedInterfaces: InterfaceListing {
    let interfaces: [RaisedInterface]

    init(_ interfaces: [RaisedInterface]) { self.interfaces = interfaces }

    func raisedInterfaces() -> [RaisedInterface] { interfaces }
}
