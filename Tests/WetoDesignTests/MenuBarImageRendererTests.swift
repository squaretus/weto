import XCTest
import AppKit
import SwiftUI
@testable import WetoDesign

final class MenuBarImageRendererTests: XCTestCase {

    func test_image_has_menu_bar_height() {
        let image = MenuBarImageRenderer.image(flag: "🇰🇿", color: .systemGreen)
        XCTAssertEqual(image.size.height, 22)
        XCTAssertGreaterThan(image.size.width, 0)
    }

    func test_image_is_not_a_template() {
        // Шаблонные изображения перекрашиваются системой в монохром,
        // а нам нужны и цвет флага, и цвет кружка статуса.
        XCTAssertFalse(MenuBarImageRenderer.image(flag: "🇰🇿", color: .systemGreen).isTemplate)
    }

    func test_identical_input_returns_cached_instance() {
        let first = MenuBarImageRenderer.image(flag: "🇰🇿", color: .systemGreen)
        let second = MenuBarImageRenderer.image(flag: "🇰🇿", color: .systemGreen)
        XCTAssertTrue(first === second)
    }

    func test_different_color_produces_different_instance() {
        let green = MenuBarImageRenderer.image(flag: "🇰🇿", color: .systemGreen)
        let red = MenuBarImageRenderer.image(flag: "🇰🇿", color: .systemRed)
        XCTAssertFalse(green === red)
    }

    func test_white_flag_is_rendered_without_crashing() {
        XCTAssertGreaterThan(
            MenuBarImageRenderer.image(flag: "🏳️", color: .systemGray).size.width,
            0
        )
    }
}

final class DesignTokensTests: XCTestCase {

    func test_adaptive_color_differs_between_schemes() {
        XCTAssertNotEqual(
            DesignTokens.textSecondary.resolve(.light),
            DesignTokens.textSecondary.resolve(.dark)
        )
    }

    func test_status_colors_are_distinct() {
        XCTAssertNotEqual(DesignTokens.green, DesignTokens.red)
        XCTAssertNotEqual(DesignTokens.green, DesignTokens.amber)
        XCTAssertNotEqual(DesignTokens.amber, DesignTokens.red)
    }

    func test_hex_initializer_maps_channels_correctly() {
        XCTAssertEqual(Color(hex: 0xFF0000), Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1))
        XCTAssertEqual(Color(hex: 0x00FF00), Color(.sRGB, red: 0, green: 1, blue: 0, opacity: 1))
        XCTAssertEqual(Color(hex: 0x0000FF), Color(.sRGB, red: 0, green: 0, blue: 1, opacity: 1))
    }
}
