import XCTest
@testable import WetoSystem
import WetoCore

final class TerminalForegroundReturnerTests: XCTestCase {

    /// Панель ищется по терминалу цели, а не по догадке: панелей на сервере много.
    func test_the_pane_is_found_by_its_terminal() {
        let listing = """
        /dev/ttys001 %0 0
        /dev/ttys004 %3 0
        """
        XCTAssertEqual(TerminalForegroundReturner.paneID(forTTY: "/dev/ttys004", in: listing), "%3")
        XCTAssertNil(TerminalForegroundReturner.paneID(forTTY: "/dev/ttys009", in: listing))
    }

    /// С общим вводом панелей `fg` ушёл бы во все панели окна, а там чужие программы.
    func test_a_pane_with_synchronized_input_is_not_typed_into() {
        let listing = """
        /dev/ttys001 %0 0
        /dev/ttys004 %3 1
        """
        XCTAssertEqual(TerminalForegroundReturner.paneID(forTTY: "/dev/ttys001", in: listing), "%0")
        XCTAssertNil(TerminalForegroundReturner.paneID(forTTY: "/dev/ttys004", in: listing))
    }

    /// Сервер tmux бывает и не родителем шелла: `tmux → zsh → bash → цель`.
    func test_tmux_is_found_above_a_nested_shell_and_only_there() {
        let processes = [
            ProcessSnapshot(pid: 90, parentPID: 1, executablePath: "/opt/homebrew/bin/tmux"),
            ProcessSnapshot(pid: 100, parentPID: 90, executablePath: "/bin/zsh"),
            ProcessSnapshot(pid: 150, parentPID: 100, executablePath: "/bin/bash"),
            ProcessSnapshot(pid: 300, parentPID: 1, executablePath: "/bin/zsh"),
        ]
        XCTAssertEqual(TerminalForegroundReturner.tmuxServer(above: processes[2], in: processes)?.pid, 90)
        XCTAssertNil(TerminalForegroundReturner.tmuxServer(above: processes[3], in: processes))
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

    // MARK: - Чей бинарник запускаем

    /// Путь к tmux взят из таблицы процессов, а назвать процесс `tmux` может кто угодно.
    /// Запускаем только то, что принадлежит root или нам и не открыто на запись другим.
    func test_only_a_binary_nobody_else_can_change_is_run() {
        let me: uid_t = 501
        XCTAssertTrue(TerminalForegroundReturner.isTrustedExecutable(owner: 0, mode: 0o755, euid: me))
        XCTAssertTrue(TerminalForegroundReturner.isTrustedExecutable(owner: me, mode: 0o755, euid: me))
        XCTAssertFalse(TerminalForegroundReturner.isTrustedExecutable(owner: 502, mode: 0o755, euid: me),
                       "чужой бинарник с именем tmux")
        XCTAssertFalse(TerminalForegroundReturner.isTrustedExecutable(owner: me, mode: 0o775, euid: me),
                       "группа может подменить")
        XCTAssertFalse(TerminalForegroundReturner.isTrustedExecutable(owner: 0, mode: 0o757, euid: me),
                       "кто угодно может подменить")
    }

    /// `/tmp` общий: каталог `tmux-<uid>` мог заранее создать другой пользователь.
    /// Требование то же, что у самого tmux.
    func test_only_our_private_socket_directory_is_used() {
        let me: uid_t = 501
        XCTAssertTrue(TerminalForegroundReturner.isTrustedSocketDirectory(owner: me, mode: 0o700, euid: me))
        XCTAssertFalse(TerminalForegroundReturner.isTrustedSocketDirectory(owner: 502, mode: 0o700, euid: me))
        XCTAssertFalse(TerminalForegroundReturner.isTrustedSocketDirectory(owner: me, mode: 0o770, euid: me))
    }

    /// От root охрана стоит над всей машиной, и ввод в чужие сессии ей не нужен и опасен.
    func test_root_types_into_nothing() {
        XCTAssertFalse(TerminalForegroundReturner.mayType(euid: 0))
        XCTAssertTrue(TerminalForegroundReturner.mayType(euid: 501))
    }
}
