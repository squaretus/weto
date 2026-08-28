import XCTest
@testable import WetoSystem
import WetoCore

/// Разрешение цели, названной одним именем.
final class TargetResolverTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("weto-resolver-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeExecutable(_ name: String, in directory: String, script: Bool = false) -> String {
        let folder = root.appendingPathComponent(directory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent(name)
        let body = script ? "#!/bin/bash\nexit 0\n" : "не скрипт\n"
        try? body.write(to: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path.path
    }

    private func resolver(_ directories: [String]) -> TargetResolver {
        TargetResolver(searchPaths: directories.map { root.appendingPathComponent($0).path })
    }

    /// Тот самый случай: `claude` лежит в `~/.local/bin`, и по имени он обязан
    /// находиться. Каталога не было в списке поиска, и цель «claude» не находилась,
    /// хотя тот же файл по полному пути добавлялся без вопросов.
    func test_a_bare_name_is_found_in_the_user_local_bin() throws {
        let expected = makeExecutable("claude", in: ".local/bin")

        let rule = try XCTUnwrap(resolver([".local/bin", "usr/bin"]).resolve("claude"))

        XCTAssertEqual(rule.path, expected)
        XCTAssertEqual(rule.displayName, "claude")
        XCTAssertEqual(rule.kind, .binary)
    }

    /// Каталоги пользователя спрашиваются раньше системных: одноимённый файл
    /// в /usr/bin не должен перебивать тот, которым человек пользуется.
    func test_user_directories_win_over_the_system_ones() throws {
        let mine = makeExecutable("codex", in: ".local/bin")
        _ = makeExecutable("codex", in: "usr/bin")

        let rule = try XCTUnwrap(resolver([".local/bin", "usr/bin"]).resolve("codex"))

        XCTAssertEqual(rule.path, mine)
    }

    /// Полный путь работал всегда — и обязан работать дальше.
    func test_an_absolute_path_still_resolves() throws {
        let path = makeExecutable("claude", in: ".local/bin")

        let rule = try XCTUnwrap(resolver([]).resolve(path))

        XCTAssertEqual(rule.path, path)
    }

    /// У скрипта с shebang `proc_pidpath` показывает интерпретатор, поэтому вид
    /// цели обязан отличаться: такие ищутся по argv, а не по пути.
    func test_a_shebang_script_is_recognised_as_a_script() throws {
        _ = makeExecutable("qwen", in: ".local/bin", script: true)

        let rule = try XCTUnwrap(resolver([".local/bin"]).resolve("qwen"))

        XCTAssertEqual(rule.kind, .script)
    }

    func test_an_unknown_name_resolves_to_nothing() {
        XCTAssertNil(resolver([".local/bin"]).resolve("такого-нет"))
    }

    /// Список каталогов по умолчанию обязан содержать те, куда ставят инструменты
    /// без пакетного менеджера: именно оттуда и не находилась цель.
    func test_the_default_list_covers_the_user_bin_directories() {
        let defaults = TargetResolver.defaultSearchPaths
        let home = NSHomeDirectory()

        XCTAssertTrue(defaults.contains("\(home)/.local/bin"))
        XCTAssertTrue(defaults.contains("/opt/homebrew/bin"))
        XCTAssertLessThan(
            defaults.firstIndex(of: "\(home)/.local/bin") ?? .max,
            defaults.firstIndex(of: "/usr/bin") ?? .max,
            "каталоги пользователя спрашиваются раньше системных"
        )
    }
}
