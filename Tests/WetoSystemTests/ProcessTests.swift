import XCTest
@testable import WetoSystem
import WetoCore

final class ProcessRegistryTests: XCTestCase {

    func test_all_processes_includes_the_test_runner_itself() {
        let processes = ProcessRegistry().allProcesses()
        let selfPID = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(
            processes.contains { $0.pid == selfPID },
            "собственный процесс не найден среди \(processes.count) перечисленных"
        )
    }

    func test_all_processes_have_non_empty_paths() {
        for process in ProcessRegistry().allProcesses() {
            XCTAssertFalse(process.executablePath.isEmpty)
        }
    }

    func test_spawned_process_is_discovered() throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sleep")
        task.arguments = ["30"]
        try task.run()
        defer { task.terminate() }

        let found = ProcessRegistry().allProcesses().first { $0.pid == task.processIdentifier }
        XCTAssertNotNil(found, "порождённый /bin/sleep не найден")
        XCTAssertEqual(found?.executablePath, "/bin/sleep")
    }

    func test_bundle_path_resolves_for_a_system_application() {
        // Finder присутствует на любой машине и на CI-раннере.
        let path = ProcessRegistry().bundlePath(forBundleID: "com.apple.finder")
        XCTAssertNotNil(path)
        XCTAssertTrue(path?.hasSuffix(".app") == true, "получено: \(path ?? "nil")")
    }

    func test_bundle_path_is_nil_for_unknown_bundle_id() {
        XCTAssertNil(ProcessRegistry().bundlePath(forBundleID: "com.weto.does.not.exist"))
    }
}

final class ProcessKillerTests: XCTestCase {

    func test_kill_terminates_a_real_process() throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sleep")
        task.arguments = ["30"]
        try task.run()
        XCTAssertTrue(task.isRunning)

        let results = ProcessKiller().kill(pids: [task.processIdentifier])

        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results[0].errorCode, "kill вернул errno \(results[0].errorCode ?? -1)")

        task.waitUntilExit()
        XCTAssertFalse(task.isRunning)
    }

    func test_kill_of_nonexistent_pid_reports_esrch() {
        // PID заведомо не существует: ядро не выдаёт настолько большие значения.
        let results = ProcessKiller().kill(pids: [Int32.max - 1])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].errorCode, ESRCH)
        XCTAssertTrue(results[0].isTerminated, "несуществующий процесс считается завершённым")
    }

    func test_kill_of_launchd_reports_eperm() {
        // PID 1 принадлежит root — ровно тот случай, который UI обязан показать
        // пользователю, а не проглотить.
        let results = ProcessKiller().kill(pids: [1])
        XCTAssertEqual(results[0].errorCode, EPERM)
        XCTAssertFalse(results[0].isTerminated)
    }

    func test_empty_pid_list_yields_empty_result() {
        XCTAssertTrue(ProcessKiller().kill(pids: []).isEmpty)
    }

    func test_results_preserve_input_order() throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sleep")
        task.arguments = ["30"]
        try task.run()

        let results = ProcessKiller().kill(pids: [Int32.max - 1, task.processIdentifier])

        XCTAssertEqual(results.map(\.pid), [Int32.max - 1, task.processIdentifier])
        task.waitUntilExit()
    }
}
