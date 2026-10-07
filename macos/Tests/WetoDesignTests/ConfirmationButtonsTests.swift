import XCTest
import AppKit
@testable import WetoDesign

@MainActor
final class ConfirmationButtonsTests: XCTestCase {

    /// Enter в подтверждении не нажимает ничего: ни «Удалить», ни «Отмена».
    /// Кнопки по умолчанию нет — и система не красит ни одну акцентом.
    func test_return_presses_no_button() {
        let alert = confirmation()

        alert.makeConfirmationButtons()

        XCTAssertFalse(alert.buttons.contains { $0.keyEquivalent == "\r" })
    }

    /// Esc — стандартная отмена: нажимает безопасную кнопку.
    func test_escape_presses_the_safe_button() {
        let alert = confirmation()

        alert.makeConfirmationButtons()

        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\u{1b}")
    }

    /// Кнопки одного вида: красного действия и залитой отмены нет.
    func test_no_button_is_singled_out() {
        let alert = confirmation()

        alert.makeConfirmationButtons()

        XCTAssertFalse(alert.buttons.contains { $0.hasDestructiveAction })
    }

    private func confirmation() -> NSAlert {
        let alert = NSAlert()
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")
        return alert
    }
}
