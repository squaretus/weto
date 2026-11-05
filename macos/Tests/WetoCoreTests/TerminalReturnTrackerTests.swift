import XCTest
@testable import WetoCore

final class TerminalReturnTrackerTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    /// Цель, потерявшая передний план при снятии паузы, возвращается сама и один раз:
    /// второй ввод `fg` в шелл уже никому не нужен.
    func test_a_target_left_in_the_background_gets_one_automatic_attempt() {
        var tracker = TerminalReturnTracker()

        XCTAssertEqual(tracker.observe(waiting: [200], at: at(0)).attempts, [200])
        XCTAssertEqual(tracker.state(of: 200), .returning)
        XCTAssertEqual(tracker.observe(waiting: [200], at: at(1)).attempts, [])
    }

    /// Команда ушла — это ещё не возврат. Решает наблюдение: цель снова впереди.
    func test_coming_back_to_the_foreground_ends_the_story() {
        var tracker = TerminalReturnTracker()
        _ = tracker.observe(waiting: [200], at: at(0))
        tracker.finished(200, succeeded: true)

        _ = tracker.observe(waiting: [], at: at(1))

        XCTAssertNil(tracker.state(of: 200))
    }

    /// Автоматика не смогла — кнопка. Она и есть запасной путь.
    func test_a_failed_automatic_attempt_offers_the_button() {
        var tracker = TerminalReturnTracker()
        _ = tracker.observe(waiting: [200], at: at(0))

        tracker.finished(200, succeeded: false)

        XCTAssertEqual(tracker.state(of: 200), .offered)
    }

    /// Команда прошла, а цель так и не вернулась: например, `fg` достался другому заданию.
    func test_a_command_that_changed_nothing_offers_the_button_too() {
        var tracker = TerminalReturnTracker()
        _ = tracker.observe(waiting: [200], at: at(0))
        tracker.finished(200, succeeded: true, at: at(0))

        _ = tracker.observe(waiting: [200], at: at(TerminalReturnTracker.verifyWindow + 1))

        XCTAssertEqual(tracker.state(of: 200), .offered)
    }

    /// Кнопка живёт максимум пять минут — от снятия паузы, а не от показа.
    func test_the_button_goes_away_after_five_minutes() {
        var tracker = TerminalReturnTracker()
        _ = tracker.observe(waiting: [200], at: at(0))
        tracker.finished(200, succeeded: false)

        _ = tracker.observe(waiting: [200], at: at(299))
        XCTAssertEqual(tracker.state(of: 200), .offered)

        _ = tracker.observe(waiting: [200], at: at(300))
        XCTAssertEqual(tracker.state(of: 200), .expired)
    }

    /// Нажатие — вторая и последняя попытка: не вышло, остаётся подсказка.
    func test_a_press_that_fails_leaves_the_hint_and_no_button() {
        var tracker = TerminalReturnTracker()
        _ = tracker.observe(waiting: [200], at: at(0))
        tracker.finished(200, succeeded: false)

        XCTAssertTrue(tracker.press(200, at: at(5)))
        XCTAssertEqual(tracker.state(of: 200), .returning)
        XCTAssertFalse(tracker.press(200, at: at(5)), "до первого нажатия — и не больше")

        tracker.finished(200, succeeded: false)
        XCTAssertEqual(tracker.state(of: 200), .failed)
    }

    /// Нажатие прошло, но цель не вернулась за отведённое время — тоже подсказка,
    /// и про этот переход узнаёт вызывающий: ему поднимать окно терминала.
    func test_a_press_that_changed_nothing_reports_the_failure_once() {
        var tracker = TerminalReturnTracker()
        _ = tracker.observe(waiting: [200], at: at(0))
        tracker.finished(200, succeeded: false)
        _ = tracker.press(200, at: at(5))
        tracker.finished(200, succeeded: true, at: at(5))

        let step = tracker.observe(waiting: [200], at: at(5 + TerminalReturnTracker.verifyWindow + 1))
        XCTAssertEqual(step.failed, [200])
        XCTAssertEqual(tracker.state(of: 200), .failed)
        XCTAssertEqual(tracker.observe(waiting: [200], at: at(30)).failed, [])
    }

    /// Новая пауза начинает историю заново: снаружи она видна как «ждать нечего»,
    /// потому что на паузе цели не возвращаются, а после неё снова положена попытка.
    func test_a_new_pause_starts_over() {
        var tracker = TerminalReturnTracker()
        _ = tracker.observe(waiting: [200], at: at(0))
        tracker.finished(200, succeeded: false)

        _ = tracker.observe(waiting: [], at: at(10))
        XCTAssertEqual(tracker.observe(waiting: [200], at: at(20)).attempts, [200])
    }

    func test_nothing_to_press_for_an_unknown_target() {
        var tracker = TerminalReturnTracker()
        XCTAssertFalse(tracker.press(200, at: at(0)))
    }
}
