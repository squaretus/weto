import XCTest
@testable import WetoShared
import WetoCore

/// Контроллер проверяется на временном plist: реальная регистрация агента в launchd
/// в тестах не нужна, а вот файл и его содержимое обязаны быть верными.
final class LaunchAgentControllerTests: XCTestCase {

    private var directory: URL!
    private var plistPath: String!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("weto-agent-\(UUID().uuidString)", isDirectory: true)
        plistPath = directory.appendingPathComponent("com.weto.app.plist").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeController(executable: String? = "/Applications/Weto.app/Contents/MacOS/WetoMenuBar") -> LaunchAgentController {
        LaunchAgentController(
            plistPath: plistPath,
            executablePath: { executable },
            uid: 0
        )
    }

    func test_enable_writes_plist_pointing_at_the_current_executable() {
        let controller = makeController()

        _ = controller.enable()

        XCTAssertTrue(controller.isInstalled)
        XCTAssertTrue(controller.pointsAtCurrentBundle)

        let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath))
        let plist = data.flatMap {
            try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil)
        } as? [String: Any]

        XCTAssertEqual(plist?["Label"] as? String, LaunchAgentController.serviceName)
        XCTAssertEqual(
            plist?["Program"] as? String,
            "/Applications/Weto.app/Contents/MacOS/WetoMenuBar"
        )
        XCTAssertEqual(plist?["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist?["KeepAlive"] as? Bool, true)
    }

    func test_enable_without_known_executable_reports_error() {
        let controller = makeController(executable: nil)

        XCTAssertEqual(controller.enable().failureValue, .missingExecutable)
        XCTAssertFalse(controller.isInstalled)
    }

    func test_agent_pointing_at_another_copy_is_detected() {
        _ = makeController(executable: "/Users/other/Weto.app/Contents/MacOS/WetoMenuBar").enable()

        let current = makeController()
        XCTAssertTrue(current.isInstalled)
        XCTAssertFalse(
            current.pointsAtCurrentBundle,
            "агент, ведущий на другую копию, обязан считаться устаревшим"
        )
    }

    func test_disable_removes_the_same_plist_it_manages() {
        let controller = makeController()
        _ = controller.enable()
        XCTAssertTrue(controller.isInstalled)

        _ = controller.disable()

        XCTAssertFalse(controller.isInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plistPath))
    }

    func test_disable_of_absent_agent_is_not_an_error() {
        let controller = makeController()
        XCTAssertTrue(controller.disable().isSuccess)
    }

    func test_default_path_is_inside_the_user_home() {

        XCTAssertEqual(
            LaunchAgentController.defaultPlistPath,
            (NSHomeDirectory() as NSString)
                .appendingPathComponent("Library/LaunchAgents/com.weto.app.plist")
        )
    }
}
