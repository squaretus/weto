import XCTest
@testable import WetoSystem
import WetoCore

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

    func test_every_service_has_non_empty_uuid_and_name() {
        for service in NetworkSnapshotReader().snapshot().services {
            XCTAssertFalse(service.uuid.isEmpty, "пустой UUID у сервиса \(service.name)")
            XCTAssertFalse(service.name.isEmpty, "пустое имя у сервиса \(service.uuid)")
        }
    }

    func test_primary_service_when_present_exists_among_services() {
        let snapshot = NetworkSnapshotReader().snapshot()
        guard let primary = snapshot.primaryServiceUUID else { return }
        XCTAssertTrue(
            snapshot.services.contains { $0.uuid == primary },
            "PrimaryService \(primary) отсутствует в списке сервисов"
        )
    }

    func test_active_interface_names_are_non_empty_when_present() {
        for service in NetworkSnapshotReader().snapshot().services {
            guard let iface = service.activeInterface else { continue }
            XCTAssertFalse(iface.isEmpty)
        }
    }

    func test_service_uuids_are_unique() {
        let services = NetworkSnapshotReader().snapshot().services
        XCTAssertEqual(Set(services.map(\.uuid)).count, services.count)
    }

    func test_repeated_reads_are_stable() {
        let reader = NetworkSnapshotReader()
        XCTAssertEqual(reader.snapshot().services.count, reader.snapshot().services.count)
    }

    func test_resolver_consumes_reader_output_end_to_end() {

        let snapshot = NetworkSnapshotReader().snapshot()
        for candidate in snapshot.vpnCandidates {
            let status = VPNStatusResolver.status(serviceID: candidate.uuid, in: snapshot)
            XCTAssertNotEqual(status, .notConfigured, "\(candidate.name) не должен давать notConfigured")
        }
    }

    func test_every_candidate_is_qualified_as_vpn() {

        for candidate in NetworkSnapshotReader().snapshot().vpnCandidates {
            XCTAssertTrue(candidate.isVPN, "\(candidate.name) попал в кандидаты без квалификации")
        }
    }

    /// Туннель, через который ядро выпускает трафик, обязан быть выбираемым.
    /// Иначе пользователь видит работающий VPN и список, в котором его нет, —
    /// так и было со сборками, поднимающими `utun` мимо сетевых сервисов.
    /// Проверка идёт по живой машине: на ней это и обнаружилось.
    func test_the_tunnel_carrying_the_traffic_is_selectable() throws {
        let snapshot = snapshotWithRoute()

        guard let carrier = snapshot.outgoing?.interface,
              ["utun", "ppp", "ipsec"].contains(where: carrier.hasPrefix)
        else { throw XCTSkip("трафик сейчас уходит не через туннель") }

        XCTAssertTrue(
            snapshot.vpnCandidates.contains { $0.activeInterface == carrier },
            "туннель \(carrier) выпускает трафик, но выбрать его нечем"
        )
    }

    /// Носитель трафика в снимке — тот же, что назовёт `route -n get` для адреса
    /// гео-сервиса. Единственная машинная сверка с системой, какая тут возможна.
    func test_the_carrier_matches_what_the_kernel_says() throws {
        let snapshot = snapshotWithRoute()
        guard let outgoing = snapshot.outgoing else {
            throw XCTSkip("наружу сейчас никто не выпускает")
        }

        let addresses = try XCTUnwrap(InterfaceAddresses.all()[outgoing.interface])
        XCTAssertTrue(
            addresses.contains(outgoing.address),
            "адрес \(outgoing.address) не принадлежит \(outgoing.interface)"
        )
    }

    /// Один туннель — один кандидат: интерфейс, уже принадлежащий сервису,
    /// не должен появиться в списке ещё и голым именем.
    func test_interface_backed_candidates_do_not_duplicate_services() {
        let snapshot = NetworkSnapshotReader().snapshot()
        let claimed = Set(
            snapshot.services.filter { !$0.isInterfaceBacked }.compactMap(\.activeInterface)
        )

        for candidate in snapshot.services where candidate.isInterfaceBacked {
            XCTAssertFalse(claimed.contains(candidate.name), "\(candidate.name) уже занят сервисом")
        }
    }

    func test_wifi_service_is_not_classified_as_vpn() throws {

        let snapshot = NetworkSnapshotReader().snapshot()
        guard let wifi = snapshot.services.first(where: { $0.name == "Wi-Fi" }) else {
            throw XCTSkip("на машине нет сервиса с именем Wi-Fi")
        }
        XCTAssertFalse(wifi.isVPN)
        XCTAssertFalse(snapshot.vpnCandidates.contains { $0.uuid == wifi.uuid })
    }
}
