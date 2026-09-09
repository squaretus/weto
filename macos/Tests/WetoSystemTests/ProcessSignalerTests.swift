import XCTest
import Darwin
@testable import WetoSystem
import WetoCore

final class ProcessSignalerTests: XCTestCase {

    private func spawnSleep() throws -> Process {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sleep")
        task.arguments = ["30"]
        try task.run()
        return task
    }

    private func snapshot(of pid: Int32) -> ProcessSnapshot? {
        ProcessRegistry().allProcesses().first { $0.pid == pid }
    }

    /// SIGSTOP виден реестру как остановленность, SIGCONT её снимает, SIGKILL завершает.
    func test_stop_resume_and_kill_are_visible_to_the_registry() throws {
        let task = try spawnSleep()
        defer { if task.isRunning { task.terminate() } }
        let pid = task.processIdentifier
        let signaler = ProcessSignaler()

        XCTAssertEqual(snapshot(of: pid)?.isStopped, false)

        XCTAssertTrue(signaler.send(.stop, to: [pid]).allSatisfy(\.isDelivered))
        // Ядру нужно мгновение, чтобы перевести процесс в SSTOP.
        usleep(50_000)
        XCTAssertEqual(snapshot(of: pid)?.isStopped, true)

        XCTAssertTrue(signaler.send(.resume, to: [pid]).allSatisfy(\.isDelivered))
        usleep(50_000)
        XCTAssertEqual(snapshot(of: pid)?.isStopped, false)

        XCTAssertTrue(signaler.send(.kill, to: [pid]).allSatisfy(\.isDelivered))
        task.waitUntilExit()
        XCTAssertNil(snapshot(of: pid))
    }

    /// Процесс, умерший до сигнала, — не ошибка: журнал пишет каждого, но ESRCH доставкой считается.
    func test_missing_process_counts_as_delivered() {
        let results = ProcessSignaler().send(.stop, to: [Int32.max - 7])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.errorCode, ESRCH)
        XCTAssertTrue(results.first?.isDelivered == true)
    }

    /// Порядок — часть контракта: шелл раньше цели на стопе, цель раньше шелла на продолжении.
    func test_signals_are_sent_in_list_order() throws {
        let first = try spawnSleep(); let second = try spawnSleep()
        defer { first.terminate(); second.terminate() }
        let results = ProcessSignaler().send(.stop, to: [second.processIdentifier, first.processIdentifier])
        XCTAssertEqual(results.map(\.pid), [second.processIdentifier, first.processIdentifier])
        _ = ProcessSignaler().send(.resume, to: [first.processIdentifier, second.processIdentifier])
    }

    /// `Foundation.Process` делает потомка лидером собственной группы (`pgid == pid`),
    /// а не наследником группы раннера: сверять надо с тем, что говорит само ядро
    /// про этот pid, а не гадать по группе родителя.
    func test_registry_reports_the_process_group() throws {
        let task = try spawnSleep()
        defer { task.terminate() }
        let pid = task.processIdentifier
        let snapshot = try XCTUnwrap(snapshot(of: pid))
        XCTAssertEqual(snapshot.processGroup, getpgid(pid))
        XCTAssertGreaterThanOrEqual(snapshot.terminalForegroundGroup, 0)
    }
}
