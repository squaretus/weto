import XCTest
import WetoSystem

/// Граница «PATH пользователя по имени» на живой машине — от своего имени:
/// `su` за другого пользователя без root недоступен, свой логин-шелл — да.
final class UserSearchPathsTests: XCTestCase {

    func test_the_own_login_shell_path_is_read() throws {
        let me = NSUserName()
        let paths = try XCTUnwrap(AccountSearchPaths().loginShellPath(ofUser: me), "логин-шелл не ответил")
        XCTAssertTrue(paths.contains("/usr/bin"), "\(paths)")
        XCTAssertEqual(AccountSearchPaths().homeDirectory(ofUser: me), NSHomeDirectory())
    }

    /// Чужого без root не спросить — ответ «шелл молчит», а не зависание и не чужой PATH.
    func test_another_user_without_root_gives_no_answer() throws {
        try XCTSkipIf(geteuid() == 0, "под root su сработал бы")
        XCTAssertNil(AccountSearchPaths().loginShellPath(ofUser: "root"))
        XCTAssertNil(AccountSearchPaths().loginShellPath(ofUser: "no-such-user-\(UUID().uuidString.prefix(8))"))
    }

    func test_a_system_command_is_found_through_the_own_path() {
        XCTAssertEqual(UserExecutableSearch.find("ls", user: NSUserName(), in: AccountSearchPaths()), "/bin/ls")
        XCTAssertNil(UserExecutableSearch.find("no-such-tool-\(UUID().uuidString.prefix(8))",
                                               user: NSUserName(), in: AccountSearchPaths()))
    }
}
