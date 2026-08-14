import XCTest
@testable import WetoShared

/// Приложение фоновое, но открытые настройки — это обычное окно: без иконки
/// в Dock его не найти ни в Cmd+Tab, ни мышью.
final class DockPolicyTests: XCTestCase {

    private let settingsWindow = WindowTrait(isVisible: true, canBecomeMain: true, isTitled: true)

    /// Попап менюбара: не титульный и не может стать главным. Считать его окном
    /// нельзя — иконка в Dock мигала бы на каждое открытие меню.
    private let menuBarPopup = WindowTrait(isVisible: true, canBecomeMain: false, isTitled: false)

    func test_no_windows_means_background_app() {
        XCTAssertFalse(DockPolicy.showsDockIcon([]))
    }

    func test_menu_bar_popup_alone_stays_background() {
        XCTAssertFalse(DockPolicy.showsDockIcon([menuBarPopup]))
    }

    func test_open_settings_window_shows_the_dock_icon() {
        XCTAssertTrue(DockPolicy.showsDockIcon([menuBarPopup, settingsWindow]))
    }

    /// Закрытое окно остаётся в списке приложения ещё какое-то время —
    /// невидимое окно за открытое не принимаем.
    func test_hidden_window_does_not_hold_the_dock_icon() {
        let closed = WindowTrait(isVisible: false, canBecomeMain: true, isTitled: true)
        XCTAssertFalse(DockPolicy.showsDockIcon([closed]))
    }

    func test_untitled_helper_window_does_not_hold_the_dock_icon() {
        let helper = WindowTrait(isVisible: true, canBecomeMain: true, isTitled: false)
        XCTAssertFalse(DockPolicy.showsDockIcon([helper]))
    }
}
