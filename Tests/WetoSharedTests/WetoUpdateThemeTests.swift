import XCTest
import SwiftUI
import UpdateKitUI
@testable import WetoShared

@MainActor
final class WetoUpdateThemeTests: XCTestCase {

    func test_theme_follows_the_application_theme() {
        let dark = WetoUpdateTheme.make(for: .dark)
        let light = WetoUpdateTheme.make(for: .light)

        XCTAssertNotEqual(dark.background, light.background)
        XCTAssertNotEqual(dark.text, light.text)
    }

    func test_theme_width_matches_the_declared_one() {
        XCTAssertEqual(WetoUpdateTheme.make(for: .dark).width, WetoUpdateTheme.width)
    }
}
