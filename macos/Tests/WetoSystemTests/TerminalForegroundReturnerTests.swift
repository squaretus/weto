import XCTest
@testable import WetoSystem
import WetoCore

final class TerminalForegroundReturnerTests: XCTestCase {

    /// Панель ищется по терминалу цели, а не по догадке: панелей на сервере много.
    func test_the_pane_is_found_by_its_terminal() {
        let listing = """
        /dev/ttys001 %0
        /dev/ttys004 %3
        """
        XCTAssertEqual(TerminalForegroundReturner.paneID(forTTY: "/dev/ttys004", in: listing), "%3")
        XCTAssertNil(TerminalForegroundReturner.paneID(forTTY: "/dev/ttys009", in: listing))
    }

    /// Terminal.app и iTerm2 находят вкладку по точному tty: `fg` не должен уйти
    /// в окно, которое просто оказалось впереди.
    func test_automation_scripts_address_the_exact_terminal() throws {
        let terminal = try XCTUnwrap(TerminalForegroundReturner.automationScript(
            bundleID: "com.apple.Terminal", tty: "/dev/ttys009"
        ))
        XCTAssertTrue(terminal.contains("tty of t is \"/dev/ttys009\""), terminal)
        XCTAssertTrue(terminal.contains("do script \"fg\" in t"), terminal)

        let iterm = try XCTUnwrap(TerminalForegroundReturner.automationScript(
            bundleID: "com.googlecode.iterm2", tty: "/dev/ttys010"
        ))
        XCTAssertTrue(iterm.contains("tty of s is \"/dev/ttys010\""), iterm)
        XCTAssertTrue(iterm.contains("write text \"fg\""), iterm)
    }

    /// Остальные эмуляторы вводить за пользователя не умеют — честный отказ, дальше кнопка.
    func test_an_unknown_terminal_has_no_automation() {
        XCTAssertNil(TerminalForegroundReturner.automationScript(bundleID: "com.github.wez.wezterm", tty: "/dev/ttys001"))
    }

    /// Цель не под tmux и терминал неизвестен: отказ сразу, без запуска чего-либо.
    func test_without_a_way_to_type_the_return_is_refused() {
        let returner = TerminalForegroundReturner(allowsAutomation: false)
        let shell = ProcessSnapshot(pid: 100, parentPID: 90, executablePath: "/bin/zsh",
                                    processGroup: 100, terminalForegroundGroup: 100, terminalDevice: 0)
        let target = ProcessSnapshot(pid: 200, parentPID: 100, executablePath: "/usr/bin/node",
                                     processGroup: 200, terminalForegroundGroup: 100, terminalDevice: 0)
        guard case .failure = returner.returnToForeground(target: target, shell: shell, processes: [shell, target], usingAutomation: true) else {
            return XCTFail("вернуть нечем")
        }
    }
}
