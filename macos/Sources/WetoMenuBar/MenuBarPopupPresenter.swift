import AppKit
import WetoShared

/// Нажимает на кнопку статус-бара, которую создал `MenuBarExtra`. Публичного API у SwiftUI для этого нет,
/// поэтому кнопка ищется среди окон строки меню; не нашлась — приложение просто активируется,
/// и пользователь откроет попап сам.
@MainActor
final class MenuBarPopupPresenter: PopupPresenting {

    func openPopup() {
        NSApplication.shared.activate()
        let button = NSApplication.shared.windows
            .filter { $0.className.contains("StatusBarWindow") }
            .compactMap { $0.contentView.flatMap(Self.statusBarButton(in:)) }
            .first
        button?.performClick(nil)
    }

    private static func statusBarButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let found = statusBarButton(in: subview) { return found }
        }
        return nil
    }
}
