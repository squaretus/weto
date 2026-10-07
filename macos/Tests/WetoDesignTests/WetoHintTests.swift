import XCTest
@testable import WetoDesign

final class WetoHintTests: XCTestCase {

    /// Кто начал набирать, подсказку уже прочитал; стёр ввод — видит её снова.
    func test_the_field_hint_shows_only_while_the_field_is_empty() {
        XCTAssertTrue(WetoHint.isShown(forFieldText: ""))
        XCTAssertFalse(WetoHint.isShown(forFieldText: "n"))
        XCTAssertFalse(WetoHint.isShown(forFieldText: " "))
    }
}
