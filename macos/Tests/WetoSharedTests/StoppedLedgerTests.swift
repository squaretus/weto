import XCTest
@testable import WetoShared
import WetoCore

@MainActor
final class StoppedLedgerTests: XCTestCase {

    private func entry(_ pid: Int32, shell: Bool = false) -> StoppedProcess {
        StoppedProcess(pid: pid, executablePath: "/p/\(pid)", stoppedAt: Date(timeIntervalSince1970: 1), isShell: shell)
    }

    /// Каждое изменение — на диск сразу: weto умирает по SIGKILL штатно, и учёт обязан пережить это.
    func test_every_change_is_persisted_immediately() {
        let storage = InMemoryStoppedLedger()
        let ledger = StoppedLedger(storage: storage)

        ledger.add([entry(100, shell: true), entry(200)])
        XCTAssertEqual(storage.load().map(\.pid), [100, 200])

        ledger.remove([200])
        XCTAssertEqual(storage.load().map(\.pid), [100])

        ledger.clear()
        XCTAssertEqual(storage.load(), [])
    }

    func test_the_same_pid_is_not_recorded_twice() {
        let ledger = StoppedLedger(storage: InMemoryStoppedLedger())
        ledger.add([entry(200)])
        ledger.add([entry(200), entry(201)])
        XCTAssertEqual(ledger.pids, [200, 201])
    }

    func test_file_round_trips_through_a_temporary_directory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = try XCTUnwrap(StoppedFile(directory: directory))
        file.save([entry(7)])
        XCTAssertEqual(file.load().map(\.pid), [7])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("stopped.json.tmp").path))
    }

    func test_corrupted_file_reads_as_empty() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: directory.appendingPathComponent("stopped.json"))
        XCTAssertEqual(StoppedFile(directory: directory)?.load(), [])
    }
}
