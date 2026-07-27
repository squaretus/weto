import SwiftUI
import AppKit
import WetoShared

private final class SingleInstanceGuard {
    static let portName = "com.weto.app.singleton" as CFString
    private var port: CFMessagePort?

    func acquire() -> Bool {
        var context = CFMessagePortContext()
        var isRemote: DarwinBoolean = false
        port = CFMessagePortCreateLocal(nil, Self.portName, { _, _, _, _ in nil }, &context, &isRemote)
        return port != nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let coordinator = AppCoordinator()
    private let instanceGuard = SingleInstanceGuard()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard instanceGuard.acquire() else {
            NSApplication.shared.terminate(nil)
            return
        }

        NSApplication.shared.setActivationPolicy(.accessory)
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.guardVM.stop()
    }
}

@main
struct WetoMenuBarApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            StatusPopupView()
                .environment(delegate.coordinator)
        } label: {
            MenuBarLabel()
                .environment(delegate.coordinator)
        }
        .menuBarExtraStyle(.window)

        Window("Настройки Weto", id: SettingsWindow.identifier) {
            SettingsWindow()
                .environment(delegate.coordinator)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
