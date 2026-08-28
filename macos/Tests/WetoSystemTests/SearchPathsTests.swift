import XCTest
@testable import WetoSystem

/// `PATH` из логин-шелла: кэш, пол между перечитываниями и поведение,
/// когда шелл промолчал.
final class SearchPathsTests: XCTestCase {

    /// Часы — граница системы: пол между перечитываниями иначе пришлось бы
    /// ждать по-настоящему.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 0)

        var now: Date {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock()
        }
    }

    private final class ShellSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [[String]]
        private(set) var calls = 0

        init(_ answers: [[String]]) { self.answers = answers }

        func read() -> [String] {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            return answers.count > 1 ? answers.removeFirst() : (answers.first ?? [])
        }
    }

    /// Шелл спрашивается один раз: разрешение цели идёт раз в две секунды
    /// на каждую цель, и запускать процесс на каждое из них нельзя.
    func test_the_shell_is_asked_once_and_then_served_from_cache() {
        let shell = ShellSpy([["/opt/homebrew/bin"]])
        let paths = LoginShellSearchPaths(readShellPath: { shell.read() })

        for _ in 0..<10 { _ = paths.searchPaths() }

        XCTAssertEqual(shell.calls, 1)
    }

    /// Порядок пользователя сохраняется, встроенный список идёт следом
    /// страховкой и без повторов.
    func test_the_user_order_is_kept_and_the_fallback_follows() {
        let shell = ShellSpy([["/Users/me/.asdf/shims", "/usr/bin"]])
        let paths = LoginShellSearchPaths(readShellPath: { shell.read() })

        let result = paths.searchPaths()

        XCTAssertEqual(result.first, "/Users/me/.asdf/shims", "шимы спрашиваются первыми")
        XCTAssertEqual(result.filter { $0 == "/usr/bin" }.count, 1, "без повторов")
        XCTAssertTrue(result.contains("/opt/homebrew/bin"), "встроенный список остаётся страховкой")
    }

    /// Шелл не ответил — остаётся встроенный список. Цель, разрешённая раньше,
    /// при этом не теряется: последнее известное правило держит `ProcessEnforcer`.
    func test_a_silent_shell_leaves_the_builtin_list() {
        let paths = LoginShellSearchPaths(readShellPath: { [] })

        let result = paths.searchPaths()

        XCTAssertEqual(result, LoginShellSearchPaths.fallbackPaths)
    }

    /// У перечитывания свой пол: ненайденное имя иначе запускало бы шелл
    /// каждые две секунды.
    func test_a_refresh_is_floored_in_time() {
        let clock = Clock()
        let shell = ShellSpy([["/one"], ["/two"]])
        let paths = LoginShellSearchPaths(readShellPath: { shell.read() }, now: { clock.now })

        _ = paths.searchPaths()
        for _ in 0..<5 { _ = paths.refreshedSearchPaths() }
        XCTAssertEqual(shell.calls, 1, "пол не пройден — шелл не тревожим")

        clock.advance(LoginShellSearchPaths.refreshFloorSeconds + 1)
        let refreshed = paths.refreshedSearchPaths()

        XCTAssertEqual(shell.calls, 2)
        XCTAssertEqual(refreshed.first, "/two", "перечитанный список и применяется")
    }
}
