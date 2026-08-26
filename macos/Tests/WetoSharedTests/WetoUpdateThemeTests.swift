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

    /// Ширина окна обязана вмещать самый длинный ряд кнопок целиком.
    ///
    /// Сжиматься кнопкам запрещено, поэтому узкое окно обрезает не подпись,
    /// а саму кнопку: «Обновить» уезжала за правый край и была видна наполовину.
    /// Число 480 стояло руками с обещанием «под самый длинный ряд», но живые
    /// контролы никто не мерил — и обещание тихо стало ложным, когда «Напомнить
    /// позже» из голого текста превратилась в пилюлю с паддингом и стрелкой.
    func test_window_is_wide_enough_for_the_longest_button_row() {
        let theme = WetoUpdateTheme.make(for: .dark)
        let later = [UpdateMenuItem(id: 0, title: "Через час", action: {})]

        let needed = UpdateDialogView.minimumWidth(fittingButtons: [
            width(of: theme.secondaryButton("Пропустить версию") {}),
            width(of: theme.menuButton("Напомнить позже", later)),
            width(of: theme.primaryButton("Обновить") {}),
        ])

        XCTAssertGreaterThanOrEqual(
            WetoUpdateTheme.width,
            needed,
            "ряду нужно \(needed) pt, а окно объявлено в \(WetoUpdateTheme.width) pt — "
                + "последняя кнопка обрежется"
        )
    }

    private func height(of view: AnyView) -> CGFloat {
        let hosting = NSHostingView(rootView: view)
        hosting.layout()
        return hosting.fittingSize.height
    }

    private func width(of view: AnyView) -> CGFloat {
        let hosting = NSHostingView(rootView: view)
        hosting.layout()
        return hosting.fittingSize.width
    }
}
