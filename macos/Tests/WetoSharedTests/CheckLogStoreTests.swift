import XCTest
@testable import WetoShared
import WetoCore

final class CheckLogStoreTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("weto-checks-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> CheckLogStore {
        CheckLogStore(storage: ChecksFile(directory: directory)!)
    }

    private func check(
        _ trigger: CheckEvent.Trigger,
        _ outcome: CheckEvent.Outcome,
        at seconds: TimeInterval = 1
    ) -> CheckEvent {
        CheckEvent(
            date: Date(timeIntervalSince1970: seconds),
            trigger: trigger,
            outcome: outcome,
            fingerprint: "out=utun6/10.2.0.5"
        )
    }

    /// Ровно тот случай, ради которого журнал проверок и заведён: пользователь
    /// нажал, запрос не ушёл, завершений не было — и следа не оставалось.
    func test_a_press_that_sent_nothing_is_recorded() {
        let log = store()

        log.record(check(.manual, .skippedProbeInFlight))

        XCTAssertEqual(log.all.count, 1)
        XCTAssertEqual(log.all.first?.trigger, .manual)
        XCTAssertEqual(log.all.first?.outcome, .skippedProbeInFlight)
        XCTAssertEqual(store().all.count, 1, "запись легла на диск сразу")
    }

    /// Рутинная удача расписания в журнал не идёт: раз в пять секунд она съела бы
    /// всю ёмкость за четыре минуты и не сказала бы ничего.
    func test_a_routine_scheduled_success_is_not_recorded() {
        let log = store()

        log.record(check(.schedule, .answered))

        XCTAssertTrue(log.all.isEmpty)
    }

    /// А вот состоявшийся запрос без ответа — идёт: это и есть отладочный материал.
    func test_a_scheduled_request_without_an_answer_is_recorded() {
        let log = store()

        log.record(check(.schedule, .failed))

        XCTAssertEqual(log.all.count, 1)
    }

    /// Смена пути и правка настроек пишутся всегда, даже удачные: их мало,
    /// и по ним видно, что охрана вообще шевелилась.
    func test_network_and_settings_checks_are_always_recorded() {
        let log = store()

        log.record(check(.networkChange, .answered))
        log.record(check(.settingsChange, .answered))

        XCTAssertEqual(log.all.count, 2)
    }

    func test_capacity_is_fifty_and_the_freshest_stay() {
        XCTAssertEqual(Constants.checkLogCapacity, 50)

        let log = store()
        for index in 0..<70 {
            log.record(check(.manual, .skippedProbeInFlight, at: TimeInterval(index)))
        }

        XCTAssertEqual(log.all.count, 50)
        XCTAssertEqual(log.all.first?.date, Date(timeIntervalSince1970: 69))
        XCTAssertEqual(log.all.last?.date, Date(timeIntervalSince1970: 20))
    }

    func test_clear_empties_the_file_too() {
        let log = store()
        log.record(check(.manual, .failed))

        log.clear()

        XCTAssertTrue(log.all.isEmpty)
        XCTAssertTrue(store().all.isEmpty)
    }
}
