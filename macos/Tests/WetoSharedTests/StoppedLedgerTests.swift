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
        XCTAssertEqual(storage.load().entries.map(\.pid), [100, 200])

        ledger.remove([200])
        XCTAssertEqual(storage.load().entries.map(\.pid), [100])

        ledger.clear()
        XCTAssertEqual(storage.load().entries, [])
    }

    func test_the_same_pid_is_not_recorded_twice() {
        let ledger = StoppedLedger(storage: InMemoryStoppedLedger())
        ledger.add([entry(200)])
        ledger.add([entry(200), entry(201)])
        XCTAssertEqual(ledger.pids, [200, 201])
    }

    /// Число ядро переиспользует, и запись про мёртвого владельца этого числа
    /// не имеет права вытеснить свежую: пара «pid + путь» у них разная, а значит
    /// это разные процессы — так их и различает всё остальное (`pause`, `settle`).
    /// Дедупликация по одному pid теряла свежую запись целиком: SIGSTOP ей уже
    /// послан, в учёт она не попадала, следующий проход вычёркивал по несовпадению
    /// путей чужую — и размораживать цель становилось некому.
    func test_a_recycled_pid_replaces_the_stale_entry_instead_of_dropping_the_fresh_one() {
        let ledger = StoppedLedger(storage: InMemoryStoppedLedger())
        ledger.add([entry(100), entry(200), entry(300)])

        let fresh = StoppedProcess(pid: 200, executablePath: "/usr/bin/claude",
                                   stoppedAt: Date(timeIntervalSince1970: 2), isShell: false)
        ledger.add([fresh])

        XCTAssertEqual(ledger.entries.map(\.executablePath), ["/p/100", "/p/300", "/usr/bin/claude"],
                       "запись про мёртвого владельца pid уступает место свежей")
        XCTAssertEqual(ledger.pids, [100, 300, 200],
                       "свежая встаёт в хвост: учёт хранит стоп-порядок, а остановлена она позже всех")
    }

    /// Порядок партии при этом свой: `resume` идёт по учёту в обратную сторону,
    /// и переставить местами цель с её шеллом значило бы сломать контракт сигналов.
    func test_a_replacement_keeps_the_order_of_its_own_batch() {
        let ledger = StoppedLedger(storage: InMemoryStoppedLedger())
        ledger.add([entry(200, shell: true)])

        ledger.add([
            StoppedProcess(pid: 200, executablePath: "/bin/zsh", stoppedAt: Date(timeIntervalSince1970: 2), isShell: true),
            entry(201),
            entry(202),
        ])

        XCTAssertEqual(ledger.pids, [200, 201, 202])
    }

    func test_file_round_trips_through_a_temporary_directory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = try XCTUnwrap(StoppedFile(directory: directory))
        file.save([entry(7)])
        XCTAssertEqual(file.load().entries.map(\.pid), [7])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("stopped.json.tmp").path))
    }

    /// Файла ещё нет — легитимно пусто, и это не должно читаться как порча:
    /// «не было» и «было, но не прочиталось» обязаны различаться.
    func test_missing_file_is_not_reported_as_corrupted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = try XCTUnwrap(StoppedFile(directory: directory))
        let readout = file.load()
        XCTAssertEqual(readout.entries, [])
        XCTAssertFalse(readout.isCorrupted)
    }

    /// Порча видна на границе, а не тонет в пустом списке: список пуст (как и раньше),
    /// но `isCorrupted` отличает этот случай от легитимно пустого файла.
    func test_corrupted_file_reads_as_empty_but_the_failure_is_visible() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: directory.appendingPathComponent("stopped.json"))
        let readout = try XCTUnwrap(StoppedFile(directory: directory)).load()
        XCTAssertEqual(readout.entries, [])
        XCTAssertTrue(readout.isCorrupted)
    }

    /// Порча файла не блокирует старт: `StoppedLedger` поднимается с пустым учётом,
    /// но само приложение может узнать, что восстановление деградировало.
    func test_ledger_starts_empty_and_flags_corruption_when_file_is_corrupted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: directory.appendingPathComponent("stopped.json"))
        let file = try XCTUnwrap(StoppedFile(directory: directory))

        let ledger = StoppedLedger(storage: file)

        XCTAssertEqual(ledger.entries, [])
        XCTAssertTrue(ledger.startedFromCorruptedFile)
    }

    /// И наоборот: легитимно пустой учёт не поднимает ложную тревогу.
    func test_ledger_does_not_flag_corruption_for_a_legitimately_empty_file() {
        let ledger = StoppedLedger(storage: InMemoryStoppedLedger())

        XCTAssertEqual(ledger.entries, [])
        XCTAssertFalse(ledger.startedFromCorruptedFile)
    }
}
