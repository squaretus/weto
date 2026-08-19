import XCTest
import AppKit
import SwiftUI
import UpdateKitUI
import WetoDesign
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

    /// Ряд кнопок окна обновления смешивает две пилюли и кнопку с меню.
    /// Пока высота бралась из шрифта и паддинга, «Напомнить позже» шла голым
    /// текстом и стояла ниже соседей — ряд выглядел разъехавшимся.
    func test_row_controls_stand_at_one_height() {
        let theme = WetoUpdateTheme.make(for: .dark)
        let later = [UpdateMenuItem(id: 0, title: "Через час", action: {})]

        let heights = [
            "пропустить": height(of: theme.secondaryButton("Пропустить версию") {}),
            "напомнить": height(of: theme.menuButton("Напомнить позже", later)),
            "обновить": height(of: theme.primaryButton("Обновить") {}),
        ]

        for (name, value) in heights {
            XCTAssertEqual(value, WetoTokens.controlHeight, accuracy: 0.5, "«\(name)»")
        }
    }

    /// Длина подписи высоту не меняет: выносные буквы и разное число слов
    /// раньше давали кнопкам разную высоту в одном ряду.
    func test_label_length_does_not_change_the_height() {
        let theme = WetoUpdateTheme.make(for: .dark)

        XCTAssertEqual(
            height(of: theme.secondaryButton("Ок") {}),
            height(of: theme.secondaryButton("Пропустить версию") {})
        )
    }

    private func height(of view: AnyView) -> CGFloat {
        let hosting = NSHostingView(rootView: view)
        hosting.layout()
        return hosting.fittingSize.height
    }
}
