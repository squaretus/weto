import XCTest
@testable import WetoCore

/// Те же случаи, что у `path_text` в `weto-core` (Linux и Windows): правило общее,
/// и расходиться платформам в нём нельзя. Случаи Windows переписаны в unix-пути —
/// регистр и обратная косая на macOS не различаются по-своему.
final class ProgramPathTests: XCTestCase {

    private func same(_ left: String, _ right: String) -> Bool {
        ProgramPath.sameProgramAcrossVersions(left, right)
    }

    func test_a_store_like_package_is_the_same_program_after_an_update() {
        XCTAssertTrue(same(
            "/Applications/WindowsApps/Claude_6.28899.6.0_x64__pzs8sxrjxfjjc/app/Claude",
            "/Applications/WindowsApps/Claude_6.30112.0.0_x64__pzs8sxrjxfjjc/app/Claude"
        ))
        // Squirrel и каталог с пробелом: версия — серия чисел через точку где угодно в сегменте.
        XCTAssertTrue(same(
            "/Users/me/Library/Discord/app-1.0.9/Discord",
            "/Users/me/Library/Discord/app-1.0.10/Discord"
        ))
        XCTAssertTrue(same(
            "/Applications/JetBrains/IntelliJ IDEA 2024.1/bin/idea",
            "/Applications/JetBrains/IntelliJ IDEA 2024.2.1/bin/idea"
        ))
        // Число до версии — не версия: `x64-` остаётся частью совпадающего начала.
        XCTAssertTrue(same("/opt/tools/x64-1.2.3/tool", "/opt/tools/x64-1.3.0/tool"))
    }

    func test_a_unix_tool_is_the_same_program_after_an_update() {
        XCTAssertTrue(same(
            "/Users/me/.nvm/versions/node/v20.11.0/lib/node_modules/@qwen-code/qwen-code/cli.js",
            "/Users/me/.nvm/versions/node/v22.1.0/lib/node_modules/@qwen-code/qwen-code/cli.js"
        ))
        XCTAssertTrue(same("/opt/discord/app-1.0.9/Discord", "/opt/discord/app-1.0.10/Discord"))
        XCTAssertTrue(same("/Applications/Tool/1.0.9/Tool", "/Applications/Tool/1.1.0/Tool"))
    }

    func test_a_different_program_is_not_another_version() {
        // Другой издатель, архитектура или пакет — другое приложение.
        let claude = "/Applications/WindowsApps/Claude_6.1.0.0_x64__pzs8sxrjxfjjc/app/Claude"
        XCTAssertFalse(same(claude, "/Applications/WindowsApps/Claude_6.2.0.0_x64__aaaaaaaaaaaaa/app/Claude"))
        XCTAssertFalse(same(claude, "/Applications/WindowsApps/Claude_6.2.0.0_arm64__pzs8sxrjxfjjc/app/Claude"))
        XCTAssertFalse(same(claude, "/Applications/WindowsApps/Other_6.2.0.0_x64__pzs8sxrjxfjjc/app/Claude"))
        // Имя файла — точно: соседняя версия интерпретатора — другая программа.
        XCTAssertFalse(same("/usr/bin/python3.11", "/usr/bin/python3.12"))
        XCTAssertFalse(same(
            "/Users/me/.local/share/claude/versions/2.1.228",
            "/Users/me/.local/share/claude/versions/2.1.300"
        ))
        XCTAssertFalse(same("/Applications/Tool/1.0.9/Tool", "/Applications/Tool/1.1.0/Updater"))
        // Одиночное число — не версия.
        XCTAssertFalse(same("/opt/Python311/python", "/opt/Python312/python"))
        XCTAssertFalse(same("/snap/code/123/usr/bin/code", "/snap/code/124/usr/bin/code"))
        // Различие не в версии, или в другом числе сегментов.
        XCTAssertFalse(same("/opt/a/1.0/tool", "/opt/b/1.0/tool"))
        XCTAssertFalse(same("/opt/a/1.0/tool", "/opt/a/1.0/bin/tool"))
        XCTAssertFalse(same("/opt/app-1.0/tool", "/opt/app-1.0-beta/tool"))
    }

    func test_a_relative_path_is_never_another_version() {
        XCTAssertFalse(same("app-1.0/tool", "/opt/app-1.1/tool"))
        XCTAssertFalse(same("tool", "tool"))
    }

    func test_the_version_is_the_first_dotted_series_of_at_least_two_numbers() {
        XCTAssertEqual(ProgramPath.versionSplit("Claude_6.28899.6.0_x64").map { [$0.head, $0.tail] },
                       ["Claude_", "_x64"])
        XCTAssertEqual(ProgramPath.versionSplit("x64-1.2.3").map { [$0.head, $0.tail] }, ["x64-", ""])
        XCTAssertEqual(ProgramPath.versionSplit("v20.11.0").map { [$0.head, $0.tail] }, ["v", ""])
        // Точка без цифры за ней серию не продолжает.
        XCTAssertEqual(ProgramPath.versionSplit("app-1.0.").map { [$0.head, $0.tail] }, ["app-", "."])
        XCTAssertNil(ProgramPath.versionSplit("Python311"))
        XCTAssertNil(ProgramPath.versionSplit("Проекты"))
        XCTAssertNil(ProgramPath.versionSplit(""))
    }
}
