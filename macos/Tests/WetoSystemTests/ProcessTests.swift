import XCTest
import Darwin
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

    /// `proc_listallpids` возвращает **количество** pid, а не число байт: делённое
    /// на `sizeof(pid_t)`, оно отдавало четверть списка — и именно свежую четверть,
    /// потому что ядро перечисляет процессы от новых к старым. Все прежние тесты
    /// порождали процесс за миг до обхода и потому проходили; невидимым оставалось
    /// то, что живёт с загрузки машины.
    func test_all_processes_include_the_oldest_process_on_the_machine() {
        let processes = ProcessRegistry().allProcesses()
        let launchd = processes.first { $0.pid == 1 }
        XCTAssertEqual(
            launchd?.executablePath, "/sbin/launchd",
            "launchd не найден среди \(processes.count) перечисленных процессов"
        )
    }

    /// Тот же обрез, увиденный со стороны количества: перечислено должно быть
    /// столько процессов, сколько их у ядра, а не четверть.
    func test_all_processes_cover_the_whole_kernel_list() {
        let expected = Int(proc_listallpids(nil, 0))
        let actual = ProcessRegistry().allProcesses().count
        XCTAssertGreaterThan(expected, 0)
        XCTAssertGreaterThan(
            Double(actual), Double(expected) * 0.5,
            "перечислено \(actual) из \(expected) — список обрезан"
        )
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

    func test_registry_returns_exact_argv_for_spawned_command() throws {

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sleep")
        task.arguments = ["30"]
        try task.run()
        defer { task.terminate() }

        let found = ProcessRegistry()
            .allProcesses(includeArguments: true)
            .first { $0.pid == task.processIdentifier }

        XCTAssertEqual(found?.arguments, ["/bin/sleep", "30"])
    }

    func test_argv_is_absent_when_not_requested() {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let found = ProcessRegistry()
            .allProcesses(includeArguments: false)
            .first { $0.pid == selfPID }

        XCTAssertNotNil(found)
        XCTAssertNil(found?.arguments)
    }

    func test_bundle_path_resolves_for_a_system_application() {

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

        let results = ProcessKiller().kill(pids: [Int32.max - 1])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].errorCode, ESRCH)
        XCTAssertTrue(results[0].isTerminated, "несуществующий процесс считается завершённым")
    }

    func test_kill_of_launchd_reports_eperm() {

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
