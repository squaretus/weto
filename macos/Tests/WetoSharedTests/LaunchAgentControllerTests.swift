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

    /// Записывает вызовы launchctl вместо настоящих: в тестах нельзя ни выгружать
    /// чужие задания, ни — тем более — задание самого раннера.
    private final class LaunchctlSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var invocations: [[String]] = []

        func run(_ arguments: [String]) -> Int32 {
            lock.lock(); invocations.append(arguments); lock.unlock()
            return 0
        }

        var calls: [[String]] {
            lock.lock(); defer { lock.unlock() }
            return invocations
        }

        var subcommands: [String] { calls.compactMap(\.first) }
    }

    private func makeController(
        executable: String? = "/Applications/Weto.app/Contents/MacOS/WetoMenuBar",
        launchctl: LaunchctlSpy = LaunchctlSpy(),
        runningAsAgent: Bool = false
    ) -> LaunchAgentController {
        LaunchAgentController(
            plistPath: plistPath,
            executablePath: { executable },
            uid: 0,
            launchdServiceName: { runningAsAgent ? LaunchAgentController.serviceName : nil },
            launchctl: { launchctl.run($0) }
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

    // Копия, поднятая launchd, сама и есть задание com.weto.app. Выгрузка задания
    // из этого процесса — SIGTERM самому себе: приложение исчезало вместе с охраной
    // в момент открытия настроек, а агент оставался снятым.
    func test_enable_does_not_boot_out_the_job_the_app_itself_is() {
        let launchctl = LaunchctlSpy()
        let controller = makeController(launchctl: launchctl, runningAsAgent: true)

        let outcome = controller.enable()

        XCTAssertTrue(outcome.isSuccess)
        XCTAssertTrue(controller.isInstalled, "файл автозапуска обязан быть записан")
        XCTAssertFalse(
            launchctl.subcommands.contains("bootout"),
            "приложение выгрузило само себя из launchd: \(launchctl.calls)"
        )
    }

    func test_disable_does_not_boot_out_the_job_the_app_itself_is() {
        let launchctl = LaunchctlSpy()
        let controller = makeController(launchctl: launchctl, runningAsAgent: true)
        _ = controller.enable()

        let outcome = controller.disable()

        XCTAssertTrue(outcome.isSuccess)
        XCTAssertFalse(controller.isInstalled, "агент обязан перестать существовать")
        XCTAssertFalse(
            launchctl.subcommands.contains("bootout"),
            "выключение автозапуска не должно завершать работающее приложение"
        )
    }

    // А вот копия, запущенная не launchd (например через open), обязана
    // перерегистрировать агент честно: иначе путь в задании останется старым.
    func test_enable_reloads_the_agent_when_the_app_is_not_the_job() {
        let launchctl = LaunchctlSpy()

        _ = makeController(launchctl: launchctl).enable()

        XCTAssertEqual(launchctl.subcommands, ["bootout", "bootstrap"])
    }

    func test_disable_boots_out_the_agent_when_the_app_is_not_the_job() {
        let launchctl = LaunchctlSpy()
        let controller = makeController(launchctl: launchctl)
        _ = controller.enable()

        _ = controller.disable()

        XCTAssertEqual(launchctl.subcommands.last, "bootout")
        XCTAssertFalse(controller.isInstalled)
    }

    func test_default_path_is_inside_the_user_home() {

        XCTAssertEqual(
            LaunchAgentController.defaultPlistPath,
            (NSHomeDirectory() as NSString)
                .appendingPathComponent("Library/LaunchAgents/com.weto.app.plist")
        )
    }
}
