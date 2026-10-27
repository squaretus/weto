import XCTest
@testable import WetoCLI

/// Сервис — отдельное задание launchd `com.weto.cli`: LaunchAgent пользователя
/// или LaunchDaemon root. Текст plist проверяется дословно по ключам, `launchctl`
/// подменён: в настоящий launchd тест не ходит.
@MainActor
final class ServiceTests: XCTestCase {

    private var h: CLIHarness!

    override func setUp() async throws {
        h = CLIHarness()
    }

    override func tearDown() async throws {
        h.tearDown()
    }

    private func plist(_ text: String) throws -> [String: Any] {
        let object = try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil)
        return try XCTUnwrap(object as? [String: Any])
    }

    func test_the_plist_runs_the_guard_interactively_and_restarts_only_after_a_crash() throws {
        let text = ServiceManager.plistText(executable: "/usr/local/bin/weto",
                                            logPath: "/Users/me/Library/Logs/weto.log")
        let dict = try plist(text)

        XCTAssertEqual(dict["Label"] as? String, "com.weto.cli")
        XCTAssertEqual(dict["ProgramArguments"] as? [String], ["/usr/local/bin/weto", "run"])
        XCTAssertEqual(dict["RunAtLoad"] as? Bool, true)
        XCTAssertEqual((dict["KeepAlive"] as? [String: Any])?["SuccessfulExit"] as? Bool, false)
        // Фоновый тип launchd троттлит таймеры — секундный опрос растянулся бы на минуты.
        XCTAssertEqual(dict["ProcessType"] as? String, "Interactive")
        XCTAssertEqual(dict["StandardOutPath"] as? String, "/Users/me/Library/Logs/weto.log")
        XCTAssertEqual(dict["StandardErrorPath"] as? String, "/Users/me/Library/Logs/weto.log")
    }

    func test_a_path_with_xml_characters_survives_the_plist() throws {
        let dict = try plist(ServiceManager.plistText(executable: "/opt/a&b <x>/weto", logPath: "/tmp/l"))
        XCTAssertEqual(dict["ProgramArguments"] as? [String], ["/opt/a&b <x>/weto", "run"])
    }

    func test_install_writes_the_plist_and_bootstraps_the_user_domain() throws {
        XCTAssertEqual(h.run("service install"), ExitCode.success)

        let written = try String(contentsOf: h.paths.servicePlist, encoding: .utf8)
        XCTAssertEqual(h.paths.servicePlist.path,
                       h.home.appendingPathComponent("Library/LaunchAgents/com.weto.cli.plist").path)
        XCTAssertEqual(try plist(written)["ProgramArguments"] as? [String], ["/usr/local/bin/weto", "run"])
        XCTAssertEqual(try plist(written)["StandardOutPath"] as? String,
                       h.home.appendingPathComponent("Library/Logs/weto.log").path)
        XCTAssertEqual(h.launchctl.calls, [
            ["print", "gui/501/com.weto.cli"],
            ["bootstrap", "gui/501", h.paths.servicePlist.path],
        ])
        XCTAssertEqual(h.output.lines, [
            "сервис установлен: \(h.paths.servicePlist.path)",
            "охрана запущена: com.weto.cli; лог — \(h.home.appendingPathComponent("Library/Logs/weto.log").path)",
        ])
        XCTAssertTrue(h.output.errors.isEmpty)
        XCTAssertFalse(h.launchctl.calls.flatMap { $0 }.contains { $0.contains("com.weto.app") },
                       "задание приложения CLI не трогает")
    }

    /// Установочный скрипт зовёт `service install` и поверх прежней установки:
    /// загруженное задание перезапускается, plist тот же — `kickstart -k`.
    func test_reinstalling_over_a_loaded_job_with_the_same_plist_kickstarts_it() {
        h.run("service install")
        h.launchctl.answers["print"] = (0, "state = running\npid = 4100")
        let before = h.launchctl.calls.count

        XCTAssertEqual(h.run("service install"), ExitCode.success)
        XCTAssertEqual(Array(h.launchctl.calls.dropFirst(before)), [
            ["print", "gui/501/com.weto.cli"],
            ["kickstart", "-k", "gui/501/com.weto.cli"],
        ])
        XCTAssertEqual(h.output.lines.last, "Сервис обновлён и перезапущен: com.weto.cli")
    }

    /// Другой plist (бинарник переехал) launchd перечитывает только при загрузке.
    func test_reinstalling_over_a_loaded_job_with_a_new_plist_reloads_it() throws {
        try FileManager.default.createDirectory(at: h.paths.servicePlist.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try ServiceManager.plistText(executable: "/opt/old/weto", logPath: "/tmp/l")
            .write(to: h.paths.servicePlist, atomically: true, encoding: .utf8)
        h.launchctl.answers["print"] = (0, "state = running\npid = 4100")

        XCTAssertEqual(h.run("service install"), ExitCode.success)
        XCTAssertEqual(h.launchctl.calls, [
            ["print", "gui/501/com.weto.cli"],
            ["bootout", "gui/501/com.weto.cli"],
            ["bootstrap", "gui/501", h.paths.servicePlist.path],
        ])
        let written = try String(contentsOf: h.paths.servicePlist, encoding: .utf8)
        XCTAssertEqual(try plist(written)["ProgramArguments"] as? [String], ["/usr/local/bin/weto", "run"])
        XCTAssertEqual(h.output.lines.last, "Сервис обновлён и перезапущен: com.weto.cli")
    }

    /// От root — LaunchDaemon в домене `system` и общий лог машины.
    func test_root_installs_a_launch_daemon_into_the_system_domain() throws {
        h.isRoot = true
        XCTAssertEqual(h.run("service install"), ExitCode.success)

        let root = h.home.appendingPathComponent("root")
        XCTAssertEqual(h.paths.servicePlist.path,
                       root.appendingPathComponent("Library/LaunchDaemons/com.weto.cli.plist").path)
        let dict = try plist(String(contentsOf: h.paths.servicePlist, encoding: .utf8))
        XCTAssertEqual(dict["StandardOutPath"] as? String, root.appendingPathComponent("Library/Logs/weto.log").path)
        XCTAssertEqual(dict["ProcessType"] as? String, "Interactive")
        XCTAssertEqual((dict["KeepAlive"] as? [String: Any])?["SuccessfulExit"] as? Bool, false)
        let attributes = try FileManager.default.attributesOfItem(atPath: h.paths.servicePlist.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o644,
                       "launchd не грузит LaunchDaemon, доступный на запись не владельцу")
        XCTAssertEqual(h.launchctl.calls, [
            ["print", "system/com.weto.cli"],
            ["bootstrap", "system", h.paths.servicePlist.path],
        ])

        h.run("service uninstall")
        XCTAssertEqual(h.launchctl.calls.last, ["bootout", "system/com.weto.cli"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.paths.servicePlist.path))
    }

    /// Бинарник из каталога сборки сменится при пересборке — сервис поднимал бы не то.
    func test_install_from_a_build_directory_warns() {
        XCTAssertTrue(ServiceManager.isInsideBuildDirectory("/src/weto/macos/.build/debug/weto"))
        XCTAssertTrue(ServiceManager.isInsideBuildDirectory("/src/weto/linux/target/release/weto-cli"))
        XCTAssertFalse(ServiceManager.isInsideBuildDirectory("/usr/local/bin/weto"))

        let manager = ServiceManager(paths: h.paths, control: h.launchctl, uid: 501)
        guard case .installed(let warnings) = manager.install(executable: "/src/macos/.build/release/weto") else {
            return XCTFail("установка обязана пройти и с предупреждением")
        }
        XCTAssertEqual(warnings, [
            "бинарник лежит в каталоге сборки (/src/macos/.build/release/weto) — сервис сломается при пересборке; "
                + "положите weto на постоянное место и установите сервис оттуда",
        ])
    }

    func test_a_refused_bootstrap_is_reported() {
        h.launchctl.answers["bootstrap"] = (5, "Bootstrap failed: 5: Input/output error")
        XCTAssertEqual(h.run("service install"), ExitCode.failure)
        XCTAssertTrue(h.output.errors.last?.contains("код 5") ?? false)
    }

    func test_uninstall_boots_out_and_removes_the_file() {
        h.run("service install")
        XCTAssertEqual(h.run("service uninstall"), ExitCode.success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.paths.servicePlist.path))
        XCTAssertEqual(h.launchctl.calls.last, ["bootout", "gui/501/com.weto.cli"])
    }

    func test_status_reads_launchctl_print() {
        h.run("service install")
        h.launchctl.answers["print"] = (0, """
        gui/501/com.weto.cli = {
        \tactive count = 1
        \tpath = /Users/me/Library/LaunchAgents/com.weto.cli.plist
        \tstate = running
        \tprogram = /usr/local/bin/weto
        \tpid = 4100
        }
        """)
        XCTAssertEqual(h.run("service status"), ExitCode.success)
        XCTAssertEqual(h.output.lines.last, "задание:  gui/501/com.weto.cli загружено, состояние running, pid 4100")

        h.launchctl.answers["print"] = (113, "Could not find service")
        h.run("service status")
        XCTAssertEqual(h.output.lines.last, "задание:  не загружено")
    }
}

/// Замок единственного экземпляра: вторая охрана не стартует и называет первую.
final class RunLockTests: XCTestCase {

    func test_the_second_acquire_is_refused_with_the_owner() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("weto-lock-\(UUID().uuidString)/run.lock")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        guard case .acquired(let fd) = RunLock.acquire(at: url, pid: 4100) else {
            return XCTFail("первый замок обязан взяться")
        }
        XCTAssertEqual(RunLock.acquire(at: url, pid: 4200), .busy(owner: 4100))

        close(fd)
        guard case .acquired(let again) = RunLock.acquire(at: url, pid: 4200) else {
            return XCTFail("освобождённый замок берётся снова")
        }
        close(again)
    }
}
