import XCTest
@testable import WetoSystem
import WetoCore

final class TerminalLocatorTests: XCTestCase {

    /// Подъём по дереву от цели через шелл до первого процесса внутри .app — эмулятора.
    /// Работает для любого эмулятора: Terminal, iTerm2, Ghostty, Warp, kitty, VS Code.
    func test_host_application_is_the_first_ancestor_inside_a_bundle() {
        let processes = [
            ProcessSnapshot(pid: 1, parentPID: 0, executablePath: "/sbin/launchd"),
            ProcessSnapshot(pid: 50, parentPID: 1, executablePath: "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
            ProcessSnapshot(pid: 100, parentPID: 50, executablePath: "/bin/zsh"),
            ProcessSnapshot(pid: 200, parentPID: 100, executablePath: "/Users/me/.local/bin/claude"),
        ]
        XCTAssertEqual(TerminalLocator.hostApplicationPID(of: 200, in: processes), 50)
    }

    /// Хелпер внутри бандла VS Code — тоже бандл; активировать надо приложение, а не хелпер:
    /// берётся самый верхний предок внутри бандла, а не первый попавшийся.
    func test_host_application_is_the_topmost_bundle_ancestor() {
        let processes = [
            ProcessSnapshot(pid: 50, parentPID: 1, executablePath: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"),
            ProcessSnapshot(pid: 60, parentPID: 50, executablePath: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"),
            ProcessSnapshot(pid: 100, parentPID: 60, executablePath: "/bin/zsh"),
            ProcessSnapshot(pid: 200, parentPID: 100, executablePath: "/c"),
        ]
        XCTAssertEqual(TerminalLocator.hostApplicationPID(of: 200, in: processes), 50)
    }

    func test_no_bundle_ancestor_means_no_terminal() {
        let processes = [
            ProcessSnapshot(pid: 1, parentPID: 0, executablePath: "/sbin/launchd"),
            ProcessSnapshot(pid: 100, parentPID: 1, executablePath: "/usr/sbin/sshd"),
            ProcessSnapshot(pid: 200, parentPID: 100, executablePath: "/c"),
        ]
        XCTAssertNil(TerminalLocator.hostApplicationPID(of: 200, in: processes))
    }
}
