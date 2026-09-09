import XCTest
import SwiftUI
@testable import WetoDesign

/// `.controlSize(.small)` раньше не давало эффекта: `WetoPillButtonStyle.makeBody`
/// не читал `@Environment(\.controlSize)` вовсе, и кнопка «Показать терминал» рядом
/// со значком паузы рендерилась той же высоты, что и обычная пилюля.
final class WetoPillButtonStyleTests: XCTestCase {

    func test_regular_control_size_uses_the_standard_pill_metrics() {
        XCTAssertEqual(WetoPillButtonStyle.height(for: .regular), WetoTokens.controlHeight)
        XCTAssertEqual(WetoPillButtonStyle.horizontalPadding(for: .regular), 15)
    }

    func test_small_control_size_is_genuinely_more_compact() {
        let compactHeight = WetoPillButtonStyle.height(for: .small)
        let compactPadding = WetoPillButtonStyle.horizontalPadding(for: .small)

        XCTAssertEqual(compactHeight, WetoTokens.controlHeightCompact)
        XCTAssertLessThan(compactHeight, WetoTokens.controlHeight)
        XCTAssertLessThan(compactPadding, 15)
    }
}
