import XCTest
import Darwin
@testable import WetoSystem

/// Настоящий pty: граница работает с устройством ядра, и подменять тут нечего.
final class TerminalModeKeeperTests: XCTestCase {

    private var master: Int32 = -1
    private var slave: Int32 = -1

    override func setUpWithError() throws {
        XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0, "pty не открылся")
    }

    override func tearDown() {
        close(master)
        close(slave)
    }

    private var device: Int32 {
        var info = stat()
        XCTAssertEqual(fstat(slave, &info), 0)
        return info.st_rdev
    }

    private func localFlags() -> tcflag_t {
        var attributes = termios()
        XCTAssertEqual(tcgetattr(slave, &attributes), 0)
        return attributes.c_lflag
    }

    private func setLocalFlags(raw: Bool) {
        var attributes = termios()
        XCTAssertEqual(tcgetattr(slave, &attributes), 0)
        let flags = tcflag_t(ICANON | ECHO | ISIG | IEXTEN)
        if raw { attributes.c_lflag &= ~flags } else { attributes.c_lflag |= flags }
        XCTAssertEqual(tcsetattr(slave, TCSANOW, &attributes), 0)
    }

    /// Ровно то, что случается с `claude`: сырой режим до паузы, режим шелла после неё,
    /// и сырой режим обратно — снаружи, по одному номеру устройства.
    func test_the_raw_mode_captured_before_the_pause_comes_back_after_the_shell_changed_it() throws {
        setLocalFlags(raw: true)
        let keeper = TerminalModeKeeper()
        let mode = try keeper.capture(device: device).get()
        XCTAssertTrue(mode.path.hasPrefix("/dev/ttys"), "путь устройства: \(mode.path)")

        setLocalFlags(raw: false)
        XCTAssertNotEqual(localFlags() & tcflag_t(ICANON), 0, "шелл вернул построчный режим")

        XCTAssertTrue(keeper.restore(mode).isSuccess)
        let flags = localFlags()
        XCTAssertEqual(flags & tcflag_t(ICANON), 0, "сырой режим вернулся")
        XCTAssertEqual(flags & tcflag_t(ECHO), 0, "эха нет — клавиши не печатаются поверх интерфейса")
        XCTAssertEqual(flags & tcflag_t(ISIG), 0)
    }

    func test_a_process_without_a_terminal_has_nothing_to_capture() {
        XCTAssertEqual(TerminalModeKeeper().capture(device: 0), .failure(.noDevice(0)))
        XCTAssertEqual(TerminalModeKeeper().capture(device: -1), .failure(.noDevice(-1)))
    }
}
