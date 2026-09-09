import AppKit
import WetoShared

/// Нажимает на кнопку статус-бара, которую создал `MenuBarExtra`. Публичного API у SwiftUI для этого нет,
/// поэтому кнопка ищется среди окон строки меню тем же приёмом, что и попап ниже: перебором
/// `NSApplication.shared.windows` по подстроке в имени класса.
///
/// `performClick(nil)` на этой кнопке — обычный клик пользователя, а он **переключает** попап
/// `MenuBarExtra` со стилем `.window`. Слепой клик закрыл бы уже открытый попап вместо того,
/// чтобы показать его, — обратное тому, что подразумевает нажатие на уведомление. Поэтому перед
/// кликом проверяется видимость: SwiftUI показывает содержимое попапа в отдельном окне
/// (замечено во время выполнения — класс вида `SwiftUI.MenuBarExtraWindow<...>`, уровень
/// `.popUpMenu`), которое появляется в `windows` при первом открытии и остаётся там же
/// (`isVisible == false`) после закрытия; клик пропускается, если такое окно уже видимо.
/// Оба поиска — по кнопке и по попапу — читают приватные, не документированные имена классов
/// и могут перестать совпадать в будущей версии AppKit/SwiftUI: тогда проверка молча перестанет
/// находить окно попапа и деградирует к прежнему поведению (клик отправляется всегда, включая
/// переключение уже открытого попапа) — не крашу и не паникует.
///
/// Кнопка не нашлась вовсе (нет соответствующего окна строки меню) — приложение только
/// активируется, клика не происходит, и пользователь открывает попап сам.
@MainActor
final class MenuBarPopupPresenter: PopupPresenting {

    func openPopup() {
        NSApplication.shared.activate()
        guard !isPopupVisible else { return }
        let button = NSApplication.shared.windows
            .filter { $0.className.contains("StatusBarWindow") }
            .compactMap { $0.contentView.flatMap(Self.statusBarButton(in:)) }
            .first
        button?.performClick(nil)
    }

    /// Окно, в котором SwiftUI рисует содержимое попапа `MenuBarExtra` со стилем `.window`.
    /// Создаётся лениво при первом открытии и после первого раза остаётся в `windows`
    /// с `isVisible == false`, пока попап закрыт, — так что до первого открытия проверка
    /// корректно даёт «не видим», а не молчаливо ищет окно, которого ещё не существует.
    private var isPopupVisible: Bool {
        NSApplication.shared.windows.contains {
            $0.isVisible && $0.className.contains("MenuBarExtraWindow")
        }
    }

    private static func statusBarButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let found = statusBarButton(in: subview) { return found }
        }
        return nil
    }
}
