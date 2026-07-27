import XCTest
@testable import WetoCore

final class CountryFlagTests: XCTestCase {

    func test_valid_code_maps_to_regional_indicator_pair() {
        XCTAssertEqual(CountryFlag.emoji(for: "KZ"), "🇰🇿")
        XCTAssertEqual(CountryFlag.emoji(for: "RU"), "🇷🇺")
    }

    func test_lowercase_code_is_normalized() {
        XCTAssertEqual(CountryFlag.emoji(for: "kz"), "🇰🇿")
    }

    func test_invalid_code_falls_back_to_white_flag() {
        XCTAssertEqual(CountryFlag.emoji(for: ""), "🏳️")
        XCTAssertEqual(CountryFlag.emoji(for: "K"), "🏳️")
        XCTAssertEqual(CountryFlag.emoji(for: "KAZ"), "🏳️")
        XCTAssertEqual(CountryFlag.emoji(for: "K1"), "🏳️")
        XCTAssertEqual(CountryFlag.emoji(for: "--"), "🏳️")
    }
}
