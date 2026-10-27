import XCTest
@testable import WetoCLI
import WetoCore
import WetoShared
import WetoSystem

/// `sudo weto target add claude`: голое имя, которого не видит root, ищется по `PATH`
/// того, кто вызвал sudo, а в запись ложится путь без разворота симлинков.
@MainActor
final class SudoTargetTests: XCTestCase {

    private var h: CLIHarness!
    private var userHome: URL!

    override func setUp() async throws {
        h = CLIHarness()
        h.isRoot = true
        h.sudoUser = "u"
        userHome = h.home.appendingPathComponent("Users/u", isDirectory: true)
        h.callerPaths.home = userHome.path
    }

    override func tearDown() async throws {
        h.tearDown()
    }

    /// Исполняемый файл в каталоге пользователя; `linkTo` — симлинком на версионный путь.
    @discardableResult
    private func install(_ name: String, in directory: String, linkTo version: String? = nil) throws -> String {
        let folder = userHome.appendingPathComponent(directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent(name).path
        if let version {
            let real = userHome.appendingPathComponent(".local/share/\(name)/versions/\(version)")
            try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: real.path, contents: Data("#!/bin/sh\n".utf8),
                                           attributes: [.posixPermissions: 0o755])
            try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: real.path)
        } else {
            FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8),
                                           attributes: [.posixPermissions: 0o755])
        }
        return path
    }

    /// 1. Имя, которое видит root, — как раньше: запись — само имя, пользователя не спрашиваем.
    func test_a_name_root_resolves_stays_a_name() {
        XCTAssertEqual(h.run("target add claude"), ExitCode.success)
        XCTAssertEqual(h.settings.targets, ["claude"])
        XCTAssertEqual(h.output.lines.count, 2)
        XCTAssertTrue(h.callerPaths.askedFor.isEmpty)
    }

    /// 2. root не видит, у пользователя в `PATH` есть — путь как лежит и третья строка.
    func test_a_name_found_in_the_callers_path_is_stored_as_that_path() throws {
        let bin = userHome.appendingPathComponent(".local/bin").path
        let path = try install("codex", in: ".local/bin", linkTo: "0.147.0")
        h.callerPaths.shellPath = ["/usr/bin", bin]

        XCTAssertEqual(h.run("target add codex"), ExitCode.success)
        XCTAssertEqual(h.settings.targets, [path], "запись — симлинк, без разворота")
        XCTAssertEqual(h.callerPaths.askedFor, ["u"])
        XCTAssertEqual(h.output.lines.first, "Цель добавлена: codex")
        XCTAssertEqual(h.output.lines.last, "  найдено в PATH пользователя u: \(path)")
        XCTAssertEqual(h.output.lines.count, 3)

        // Повтор — тот же путь, отказ прежним текстом; снять — по имени.
        XCTAssertEqual(h.run("target add codex"), ExitCode.failure)
        XCTAssertEqual(h.output.errors.last, "такая цель уже есть в списке")
        XCTAssertEqual(h.run("target remove codex"), ExitCode.success)
        XCTAssertTrue(h.settings.targets.isEmpty)
    }

    /// 3. Шелл промолчал — общепринятые каталоги в доме пользователя.
    func test_a_silent_shell_falls_back_to_the_usual_directories() throws {
        h.callerPaths.shellPath = nil
        let path = try install("codex", in: ".cargo/bin")

        XCTAssertEqual(h.run("target add codex"), ExitCode.success)
        XCTAssertEqual(h.settings.targets, [path])
        XCTAssertEqual(h.output.lines.last, "  найдено в PATH пользователя u: \(path)")
    }

    /// 4. Не найдено нигде — как раньше: имя и прежняя подсказка.
    func test_nothing_found_keeps_the_old_hint() {
        h.callerPaths.shellPath = ["/nonexistent"]
        XCTAssertEqual(h.run("target add codex"), ExitCode.success)
        XCTAssertEqual(h.settings.targets, ["codex"])
        XCTAssertEqual(h.output.lines, ["Цель добавлена: codex", "  не найдено по имени — укажите полный путь к файлу"])
    }

    /// 5. Без `SUDO_USER`, с `SUDO_USER=root` или не под root — поведение прежнее.
    func test_without_a_sudo_caller_nothing_changes() throws {
        try install("codex", in: ".local/bin")
        h.callerPaths.shellPath = [userHome.appendingPathComponent(".local/bin").path]

        for setup in [{ (h: CLIHarness) in h.sudoUser = nil },
                      { (h: CLIHarness) in h.sudoUser = "root" },
                      { (h: CLIHarness) in h.isRoot = false }] {
            let harness = CLIHarness()
            defer { harness.tearDown() }
            harness.isRoot = true
            harness.sudoUser = "u"
            harness.callerPaths.shellPath = h.callerPaths.shellPath
            harness.callerPaths.home = h.callerPaths.home
            setup(harness)
            XCTAssertEqual(harness.run("target add codex"), ExitCode.success)
            XCTAssertEqual(harness.settings.targets, ["codex"])
            XCTAssertTrue(harness.callerPaths.askedFor.isEmpty)
        }
    }

    /// Ветка «приложение» в `vpn set`: та же находка и та же третья строка.
    func test_vpn_set_finds_the_app_in_the_callers_path() throws {
        let path = try install("happ-cli", in: "bin")
        h.callerPaths.shellPath = nil

        XCTAssertEqual(h.run("vpn set happ-cli"), ExitCode.success)
        XCTAssertEqual(h.settings.vpnAppRule, path)
        XCTAssertNil(h.settings.vpnTunnel)
        XCTAssertEqual(h.output.lines, [
            "VPN-приложение: happ-cli (\(path))",
            "  найдено в PATH пользователя u: \(path)",
        ])
        XCTAssertEqual(h.callerPaths.askedFor, ["u"], "чужой шелл спрошен один раз")
    }

    /// Каталоги запасного поиска — по ТЗ, в его порядке.
    func test_the_fallback_directories_are_the_contract_ones() {
        XCTAssertEqual(UserExecutableSearch.fallbackDirectories(home: "/Users/u"), [
            "/Users/u/.local/bin", "/Users/u/bin", "/Users/u/.cargo/bin", "/Users/u/.bun/bin",
            "/Users/u/.deno/bin", "/Users/u/.npm-global/bin", "/opt/homebrew/bin", "/usr/local/bin",
        ])
    }

    /// Вывод шелла: профиль волен печатать что угодно — берётся только значение после метки.
    func test_the_shell_output_is_read_after_the_marker() {
        XCTAssertEqual(AccountSearchPaths.parse("Добро пожаловать!\nfortune\n\nWETO_PATH=/a/bin::/usr/bin\n"),
                       ["/a/bin", "/usr/bin"])
        XCTAssertNil(AccountSearchPaths.parse("ничего"))
        XCTAssertNil(AccountSearchPaths.parse("\nWETO_PATH="))
    }
}
