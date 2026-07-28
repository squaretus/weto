import XCTest
@testable import WetoXPC
import WetoCore

/// Демон в тестах не поднимается: проверяется разбор его ответов и то,
/// что клиент не выдумывает результат при мусоре на входе.
final class UpdateServiceTests: XCTestCase {

    private func info(latest: String, current: String, isNewer: Bool, pkg: String = "") -> Data {
        try! JSONEncoder().encode(UpdateInfo(
            currentVersion: current,
            latestVersion: latest,
            releaseURL: "https://github.com/squaretus/weto/releases/tag/v\(latest)",
            downloadURL: pkg,
            releaseNotes: nil,
            isNewer: isNewer
        ))
    }

    func test_newer_release_becomes_available() {
        let result = UpdateService.result(
            data: info(latest: "1.2.0", current: "1.0.0", isNewer: true, pkg: "https://example.com/w.pkg"),
            error: nil
        )
        guard case .available(let update) = result else {
            return XCTFail("ожидалось .available, получено \(result)")
        }
        XCTAssertEqual(update.latestVersion, "1.2.0")
        XCTAssertEqual(update.downloadURL, "https://example.com/w.pkg")
    }

    func test_same_version_becomes_up_to_date() {
        let result = UpdateService.result(
            data: info(latest: "1.0.0", current: "1.0.0", isNewer: false),
            error: nil
        )
        XCTAssertEqual(result, .upToDate(currentVersion: "1.0.0"))
    }

    func test_daemon_error_is_passed_through() {
        XCTAssertEqual(
            UpdateService.result(data: nil, error: "нет сети"),
            .failed("нет сети")
        )
    }

    func test_garbage_payload_is_a_failure_not_a_verdict() {

        XCTAssertEqual(
            UpdateService.result(data: Data("не json".utf8), error: nil),
            .failed("Не удалось разобрать ответ демона")
        )
        XCTAssertEqual(
            UpdateService.result(data: nil, error: nil),
            .failed("Не удалось разобрать ответ демона")
        )
    }

    func test_protocol_version_is_pinned() {

        XCTAssertEqual(WetoXPCConstants.machServiceName, "com.weto.helper")
        XCTAssertFalse(WetoXPCConstants.protocolVersion.isEmpty)
    }
}
