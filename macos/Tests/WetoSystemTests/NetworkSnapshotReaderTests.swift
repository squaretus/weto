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
        let snapshot = NetworkSnapshotReader(routeProbe: FixedRoute(route)).snapshot()

        XCTAssertEqual(snapshot.outgoing, route)
        XCTAssertEqual(snapshot.verdictFingerprint, "out=utun9/10.7.0.2")
    }

    func test_without_a_route_the_snapshot_is_empty() {
        let snapshot = NetworkSnapshotReader(routeProbe: FixedRoute(nil)).snapshot()

        XCTAssertNil(snapshot.outgoing)
        XCTAssertEqual(snapshot.verdictFingerprint, "out=-")
    }
}

private struct FixedRoute: RouteProbing {
    let route: OutgoingRoute?

    init(_ route: OutgoingRoute?) { self.route = route }

    func outgoingRoute() -> OutgoingRoute? { route }
}
