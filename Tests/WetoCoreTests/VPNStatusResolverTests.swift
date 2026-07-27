import XCTest
@testable import WetoCore

final class VPNStatusResolverTests: XCTestCase {

    /// Снимок снят с машины владельца 2026-07-27, см. раздел 13 спеки.
    private let snapshot = NetworkSnapshot(
        services: [
            .init(uuid: "108E2488", name: "Wi-Fi", activeInterface: "en0"),
            .init(uuid: "BC2D1D42", name: "Happ", activeInterface: "utun6"),
            .init(uuid: "F8D44BFF", name: "Tailscale", activeInterface: "utun7"),
            .init(uuid: "AC98ABFF", name: "KARO", activeInterface: nil),
            .init(uuid: "9BA5C511", name: "iPhone", activeInterface: nil),
            .init(uuid: "13102BC0", name: "Thunderbolt Bridge", activeInterface: nil),
        ],
        primaryServiceUUID: "BC2D1D42"
    )

    func test_nil_name_is_not_configured() {
        XCTAssertEqual(VPNStatusResolver.status(serviceName: nil, in: snapshot), .notConfigured)
    }

    func test_unknown_service_name_is_down() {
        // Сервис удалили из системных настроек, а в наших настройках он остался.
        XCTAssertEqual(VPNStatusResolver.status(serviceName: "Ghost", in: snapshot), .down)
    }

    func test_configured_but_not_active_service_is_down() {
        XCTAssertEqual(VPNStatusResolver.status(serviceName: "KARO", in: snapshot), .down)
    }

    func test_active_service_holding_default_route_is_up_and_primary() {
        XCTAssertEqual(
            VPNStatusResolver.status(serviceName: "Happ", in: snapshot),
            .up(isPrimary: true)
        )
    }

    func test_active_service_not_holding_default_route_is_up_but_not_primary() {
        // Tailscale поднят, но default route держит Happ — ровно тот случай,
        // ради которого проверяется PrimaryService.
        XCTAssertEqual(
            VPNStatusResolver.status(serviceName: "Tailscale", in: snapshot),
            .up(isPrimary: false)
        )
    }

    func test_no_primary_service_means_not_primary() {
        let orphan = NetworkSnapshot(services: snapshot.services, primaryServiceUUID: nil)
        XCTAssertEqual(
            VPNStatusResolver.status(serviceName: "Happ", in: orphan),
            .up(isPrimary: false)
        )
    }

    func test_candidate_names_are_sorted_case_insensitively_and_unique() {
        // Регистр не должен влиять на порядок: "iPhone" стоит между "Happ" и "KARO",
        // а не в конце списка, как было бы при сортировке по скалярам Unicode.
        XCTAssertEqual(
            snapshot.vpnCandidateNames,
            ["Happ", "iPhone", "KARO", "Tailscale", "Thunderbolt Bridge", "Wi-Fi"]
        )
    }

    func test_duplicate_service_names_collapse_into_one_candidate() {
        let withDuplicate = NetworkSnapshot(
            services: snapshot.services + [
                .init(uuid: "OTHER", name: "Happ", activeInterface: nil)
            ],
            primaryServiceUUID: "BC2D1D42"
        )
        XCTAssertEqual(withDuplicate.vpnCandidateNames.filter { $0 == "Happ" }.count, 1)
    }
}
