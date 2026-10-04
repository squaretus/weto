import XCTest
@testable import WetoCore

final class PauseCeilingTests: XCTestCase {

    func test_the_choices_are_one_two_five_and_ten_minutes_in_that_order() {
        XCTAssertEqual(PauseCeiling.allCases.map(\.seconds), [60, 120, 300, 600])
        XCTAssertEqual(PauseCeiling.allCases.map(\.title), ["1 мин", "2 мин", "5 мин", "10 мин"])
    }

    /// Установка, жившая с жёсткой минутой, обязана открыться с ней же.
    func test_a_missing_or_unknown_stored_value_falls_back_to_one_minute() {
        XCTAssertEqual(PauseCeiling.standard, .oneMinute)
        XCTAssertEqual(PauseCeiling(storedSeconds: nil), .oneMinute)
        XCTAssertEqual(PauseCeiling(storedSeconds: 90), .oneMinute)
        XCTAssertEqual(PauseCeiling(storedSeconds: 300), .fiveMinutes)
    }

    func test_duration_text_names_whole_minutes_and_falls_back_to_seconds() {
        XCTAssertEqual(PauseCeiling.durationText(60), "1 мин")
        XCTAssertEqual(PauseCeiling.durationText(600), "10 мин")
        XCTAssertEqual(PauseCeiling.durationText(90), "90 с")
        XCTAssertEqual(PauseCeiling.durationText(30), "30 с")
    }
}
