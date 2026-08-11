import AppKit
import SwiftUI
import UpdateKit

/// Показ окна обновления. Окно — `NSWindow` с `NSHostingController` внутри,
/// а не SwiftUI-сцена: приложение в менюбаре создаёт содержимое лениво,
/// и сцену пришлось бы будить окольным путём.
@MainActor
public final class UpdateWindowPresenter: NSObject, NSWindowDelegate {

    private let controller: UpdateController
    private let theme: @MainActor () -> UpdateTheme
    private var window: NSWindow?

    public init(controller: UpdateController, theme: @escaping @MainActor () -> UpdateTheme) {
        self.controller = controller
        self.theme = theme
        super.init()

        controller.presentationHandler = { [weak self] isPresented in
            isPresented ? self?.show() : self?.hide()
        }
    }

    public func show() {
        let window = self.window ?? makeWindow()
        window.contentViewController = NSHostingController(
            rootView: UpdateDialogView(controller: controller, theme: theme())
        )
        window.center()
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    public func hide() {
        window?.orderOut(nil)
    }

    /// Закрытие крестиком равно «напомнить позже»: молчаливое закрытие
    /// не должно означать «больше никогда».
    public func windowWillClose(_ notification: Notification) {
        guard controller.isDialogPresented else { return }
        controller.dismissDialog()
    }

    private func makeWindow() -> NSWindow {
        let created = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        created.titlebarAppearsTransparent = true
        created.titleVisibility = .hidden
        created.isMovableByWindowBackground = true
        created.isReleasedWhenClosed = false
        created.level = .floating
        created.delegate = self
        created.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        created.standardWindowButton(.zoomButton)?.isEnabled = false
        window = created
        return created
    }
}
