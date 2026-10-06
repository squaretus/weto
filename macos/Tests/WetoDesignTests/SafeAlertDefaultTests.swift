import XCTest
import AppKit
@testable import WetoDesign

@MainActor
final class SafeAlertDefaultTests: XCTestCase {

    /// Enter нажимает безопасную кнопку: случайный Enter в «Удалить Weto?» не удаляет.
    func test_return_presses_the_safe_button_not_the_action() {
        let alert = NSAlert()
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")

        alert.makeSafeButtonDefault()

        XCTAssertEqual(alert.buttons[0].keyEquivalent, "")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\r")
    }

    func test_the_action_button_is_marked_destructive() {
        let alert = NSAlert()
        alert.addButton(withTitle: "Удалить всё равно")
        alert.addButton(withTitle: "Не удалять и закрыть Weto")

        alert.makeSafeButtonDefault()

        XCTAssertTrue(alert.buttons[0].hasDestructiveAction)
    }
}
