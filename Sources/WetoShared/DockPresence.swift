import AppKit
import Foundation

/// Признаки окна, по которым решается, показывать ли приложение в Dock.
/// Отдельный тип, чтобы правило проверялось тестом без живых `NSWindow`.
public struct WindowTrait: Equatable, Sendable {
    public let isVisible: Bool
    public let canBecomeMain: Bool
    public let isTitled: Bool

    public init(isVisible: Bool, canBecomeMain: Bool, isTitled: Bool) {
        self.isVisible = isVisible
        self.canBecomeMain = canBecomeMain
        self.isTitled = isTitled
    }
}

public enum DockPolicy {

    /// Приложение показывается в Dock, пока открыто хоть одно настоящее окно —
    /// настройки или окно обновления. Попап менюбара таким окном не считается:
    /// он не титульный и не может стать главным, иначе иконка в Dock мигала бы
    /// на каждое открытие меню.
    public static func showsDockIcon(_ windows: [WindowTrait]) -> Bool {
        windows.contains { $0.isVisible && $0.canBecomeMain && $0.isTitled }
    }
}

/// Держит присутствие приложения в Dock в согласии с открытыми окнами.
///
/// Приложение живёт в менюбаре и по умолчанию фоновое (`LSUIElement` плюс
/// `.accessory`), но открытые настройки — это уже обычное окно: без иконки
/// в Dock и меню приложения его не найти ни в Cmd+Tab, ни мышью.
///
/// Наблюдатели — через `addObserver` со stored token, а не async sequence:
/// `Notification` не `Sendable` под Swift 6.
@MainActor
public final class DockPresence {

    private var tokens: [NSObjectProtocol] = []

    public init() {}

    deinit {
        // Токены сняты в `stop()`; здесь их уже не тронуть — deinit не на акторе.
    }

    /// Подписывается на появление и закрытие окон. Отдельных вызовов из View
    /// не нужно: любое наше окно, став ключевым, сообщает о себе само.
    public func start() {
        guard tokens.isEmpty else { return }

        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                // Закрывающееся окно ещё в списке приложения, поэтому решение
                // принимаем на следующем витке цикла, когда список уже верный.
                Task { @MainActor [weak self] in self?.refresh() }
            }
            tokens.append(token)
        }
        refresh()
    }

    public func stop() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
    }

    public func refresh() {
        let traits = NSApplication.shared.windows.map {
            WindowTrait(
                isVisible: $0.isVisible,
                canBecomeMain: $0.canBecomeMain,
                isTitled: $0.styleMask.contains(.titled)
            )
        }

        let policy: NSApplication.ActivationPolicy =
            DockPolicy.showsDockIcon(traits) ? .regular : .accessory
        guard NSApplication.shared.activationPolicy() != policy else { return }
        NSApplication.shared.setActivationPolicy(policy)
    }
}
