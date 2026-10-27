import XCTest
@testable import WetoCLI
import WetoCore
import WetoShared
import WetoSystem

/// Охрана всей машины от root. Хранилище выбирает эффективный uid; обычный
/// пользователь рядом с системной установкой видит её статус, а за остальным
/// идёт через sudo.
@MainActor
final class SystemModeTests: XCTestCase {

    private var h: CLIHarness!

    override func setUp() async throws {
        h = CLIHarness()
    }

    override func tearDown() async throws {
        h.tearDown()
    }

    func test_the_system_storage_lives_where_the_contract_says() {
        let paths = CLIPaths.system()
        XCTAssertTrue(paths.isSystem)
        XCTAssertEqual(paths.dataDirectory.path, "/Library/Application Support/weto")
        XCTAssertEqual(paths.statusFile.path, "/Library/Application Support/weto/status.json")
        XCTAssertEqual(paths.tokenFile.path, "/Library/Application Support/weto/token")
        XCTAssertEqual(paths.lockFile.path, "/Library/Application Support/weto/run.lock")
        XCTAssertEqual(paths.servicePlist.path, "/Library/LaunchDaemons/com.weto.cli.plist")
        XCTAssertEqual(paths.logFile.path, "/Library/Logs/weto.log")

        let user = CLIPaths.user(home: URL(fileURLWithPath: "/Users/me"))
        XCTAssertFalse(user.isSystem)
        XCTAssertEqual(user.dataDirectory.path, "/Users/me/Library/Application Support/weto-cli")
        XCTAssertEqual(user.servicePlist.path, "/Users/me/Library/LaunchAgents/com.weto.cli.plist")
    }

    /// Каталог системной установки открыт на чтение: `status.json` читается без sudo.
    func test_the_system_directory_is_world_readable_even_under_a_strict_umask() throws {
        let previous = umask(0o077)
        defer { umask(previous) }
        h.systemPaths.prepareSystemDirectory()

        let attributes = try FileManager.default.attributesOfItem(atPath: h.systemPaths.dataDirectory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        XCTAssertTrue(h.systemPaths.isInstalled, "каталог данных — признак системной установки")
    }

    func test_root_keeps_the_token_in_the_system_directory() throws {
        h.isRoot = true
        XCTAssertEqual(h.run("token set s3cret"), ExitCode.success)
        let attributes = try FileManager.default.attributesOfItem(atPath: h.systemPaths.tokenFile.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.userPaths.tokenFile.path))
    }

    /// Чтение и правки у не-root рядом с системной установкой — подсказка про sudo, код 1.
    func test_a_user_beside_a_system_install_is_sent_to_sudo() {
        h.installSystemGuard()
        // Аргументы — как введены: подсказку копируют целиком.
        let refused = [
            "target list", "target add claude", "vpn show", "vpn set wg0", "vpn list", "blacklist list",
            "timeout show", "timeout set 5", "token show", "token set", "journal", "check",
            "service install", "service uninstall", "update install", "update",
        ]
        for line in refused {
            XCTAssertEqual(h.run(line), ExitCode.failure, line)
            XCTAssertEqual(h.output.errors.last, "охрана установлена на всю машину — sudo weto \(line)", line)
        }
        XCTAssertTrue(h.settings.targets.isEmpty, "правка не легла в пользовательский набор")
        XCTAssertNil(h.settings.vpnTunnel)
        XCTAssertTrue(h.guardProcess.checksRequested.isEmpty, "root-процессу сигнал не шлётся")
        XCTAssertNotNil(CLI.systemInstallRefusal(.run, env: h.cli.env), "своя охрана рядом с системной не стартует")
    }

    /// Токен в подсказку не попадает никогда: она печатается на экран и уходит в логи.
    func test_the_hint_for_token_set_drops_the_token() {
        h.installSystemGuard()
        XCTAssertEqual(h.run("token set s3cret"), ExitCode.failure)
        XCTAssertEqual(h.output.errors, ["охрана установлена на всю машину — sudo weto token set"])
        XCTAssertFalse((h.output.lines + h.output.errors).contains { $0.contains("s3cret") })
        XCTAssertEqual(h.settings.ipinfoToken, "", "токен не сохранён")
    }

    func test_help_version_and_update_check_work_beside_a_system_install() {
        h.installSystemGuard()
        XCTAssertEqual(h.run("version"), ExitCode.success)
        XCTAssertEqual(h.run("help"), ExitCode.success)
        h.releases.publish(version: "0.2.0", archive: nil, sums: nil)
        XCTAssertEqual(h.run("update check"), ExitCode.success)
        XCTAssertTrue(h.output.errors.isEmpty)
    }

    /// Без системной установки обычный пользователь работает со своим хранилищем.
    func test_without_a_system_install_the_user_storage_is_used() {
        XCTAssertEqual(h.run("target add claude"), ExitCode.success)
        XCTAssertEqual(h.settings.targets, ["claude"])
        XCTAssertNil(CLI.systemInstallRefusal(.run, env: h.cli.env))
    }

    /// `status` рядом с системной установкой читает её файл: он `0644`.
    func test_status_beside_a_system_install_reads_the_system_file() throws {
        h.installSystemGuard()
        h.guardProcess.alive = [100]
        try GuardStatus(
            pid: 100, updatedAt: h.now, lastProbeAt: nil,
            phase: .init(kind: "protected", title: "На страже", action: "цели работают", evidence: "—"),
            pauseDeadline: nil, reading: nil, outgoing: nil,
            vpn: .init(kind: "tunnel", name: "wg0", status: "carrying", via: nil),
            targets: [], pauseCeilingSeconds: 60, updateAvailable: "0.3.0"
        ).write(to: h.systemPaths.statusFile)

        XCTAssertEqual(h.run("status"), ExitCode.success)
        XCTAssertEqual(h.output.lines.first, "Охрана:   На страже — цели работают")
        XCTAssertEqual(h.output.lines.last, "Обновление: доступна версия 0.3.0 — sudo weto update")
    }

    func test_status_beside_a_stopped_system_guard_points_to_sudo() {
        h.installSystemGuard()
        XCTAssertEqual(h.run("status"), ExitCode.notRunning)
        XCTAssertEqual(h.output.lines, ["Охрана не запущена: sudo weto service install"])
        XCTAssertEqual(h.output.errors, ["охрана установлена на всю машину — sudo weto status"])
    }

    /// `launchctl print system/…` обычному пользователю доступен — задание root он и видит.
    func test_service_status_beside_a_system_install_shows_the_daemon() {
        h.installSystemGuard()
        h.launchctl.answers["print"] = (0, "state = running\npid = 100")
        XCTAssertEqual(h.run("service status"), ExitCode.success)
        XCTAssertEqual(h.launchctl.calls, [["print", "system/com.weto.cli"]])
        XCTAssertEqual(h.output.lines.last, "задание:  system/com.weto.cli загружено, состояние running, pid 100")
    }

    // MARK: - Приложение Weto

    struct FixedProcesses: ProcessLocating {
        let paths: [String]
        func bundlePath(forBundleID bundleID: String) -> String? { nil }
        func allProcesses(includeArguments: Bool) -> [ProcessSnapshot] {
            paths.enumerated().map { ProcessSnapshot(pid: Int32($0.offset + 100), executablePath: $0.element) }
        }
    }

    /// Признак приложения подделывает любой пользователь, поэтому охрана всей машины
    /// из-за него не останавливается: стартует и предупреждает. Пользовательская — нет.
    func test_a_whole_machine_guard_never_refuses_because_of_an_app() {
        XCTAssertEqual(GuardRunner.appConflict(isSystem: true, appIsRunning: true), .warn)
        XCTAssertEqual(GuardRunner.appConflict(isSystem: false, appIsRunning: true), .refuse)
        XCTAssertEqual(GuardRunner.appConflict(isSystem: true, appIsRunning: false), .none)
        XCTAssertEqual(GuardRunner.appConflict(isSystem: false, appIsRunning: false), .none)
    }

    /// Приложение любого пользователя видно обходом процессов — без GUI-сессии.
    func test_the_weto_app_is_found_by_walking_processes() {
        XCTAssertTrue(WetoAppProcessDetector(locator: FixedProcesses(paths: [
            "/sbin/launchd", "/Applications/Weto.app/Contents/MacOS/WetoMenuBar",
        ])).isWetoAppRunning)
        XCTAssertTrue(WetoAppProcessDetector(locator: FixedProcesses(paths: [
            "/Users/other/Applications/Weto.app/Contents/MacOS/WetoMenuBar",
        ])).isWetoAppRunning)
        XCTAssertFalse(WetoAppProcessDetector(locator: FixedProcesses(paths: [
            "/Library/PrivilegedHelperTools/com.weto.helper", "/usr/local/bin/weto",
            "/Applications/Happ.app/Contents/MacOS/Happ",
        ])).isWetoAppRunning, "демон обновления и сам weto приложением не считаются")
    }
}

/// След системной установки оставляют только правки root, охрана и сервис.
@MainActor
final class SystemInstallMarkTests: XCTestCase {

    func test_only_root_edits_mark_the_machine() throws {
        let h = CLIHarness()
        defer { h.tearDown() }
        h.isRoot = true

        h.releases.publish(version: "0.2.0", archive: nil, sums: nil)
        for line in ["version", "help", "status", "target list", "update check", "update"] {
            h.run(line)
        }
        XCTAssertFalse(h.systemPaths.isInstalled,
                       "sudo weto update у пользователя со своей установкой не отрезает его от хранилища")

        XCTAssertEqual(h.run("target add claude"), ExitCode.success)
        XCTAssertTrue(h.systemPaths.isInstalled)
        let attributes = try FileManager.default.attributesOfItem(atPath: h.systemPaths.dataDirectory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }
}
