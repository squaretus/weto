import XCTest
@testable import WetoDesign

final class WetoPauseBadgeTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000)

    func test_countdown_rounds_up_and_never_goes_negative() {
        XCTAssertEqual(WetoPauseBadge.countdown(until: t0.addingTimeInterval(42.2), at: t0), "43 с")
        XCTAssertEqual(WetoPauseBadge.countdown(until: t0.addingTimeInterval(1), at: t0), "1 с")
        XCTAssertEqual(WetoPauseBadge.countdown(until: t0, at: t0.addingTimeInterval(5)), "0 с")
    }

    /// Больше минуты — минуты и секунды: «599 с» не читается. Последняя минута —
    /// по-прежнему «43 с».
    func test_countdown_switches_to_minutes_above_one_minute() {
        XCTAssertEqual(WetoPauseBadge.countdown(until: t0.addingTimeInterval(600), at: t0), "10:00")
        XCTAssertEqual(WetoPauseBadge.countdown(until: t0.addingTimeInterval(299.2), at: t0), "5:00")
        XCTAssertEqual(WetoPauseBadge.countdown(until: t0.addingTimeInterval(61), at: t0), "1:01")
        XCTAssertEqual(WetoPauseBadge.countdown(until: t0.addingTimeInterval(60), at: t0), "60 с")
    }

    func test_countdown_without_a_deadline_just_says_paused() {
        XCTAssertEqual(WetoPauseBadge.countdown(until: nil, at: t0), "пауза")
    }
}
