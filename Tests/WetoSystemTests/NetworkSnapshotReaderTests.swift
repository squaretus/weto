import XCTest
@testable import WetoSystem
import WetoCore

final class NetworkSnapshotReaderTests: XCTestCase {

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
        for name in snapshot.vpnCandidateNames {
            let status = VPNStatusResolver.status(serviceName: name, in: snapshot)
            XCTAssertNotEqual(status, .notConfigured, "имя \(name) не должно давать notConfigured")
        }
    }
}
