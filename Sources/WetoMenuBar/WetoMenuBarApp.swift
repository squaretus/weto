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

        // Копию, поднятую launchd (после установки и после каждого входа в систему),
        // macOS считает праздной и усыпляет автозавершением. Момент, когда у приложения
        // не остаётся ни одного окна — попап менюбара закрылся, а окно настроек ещё
        // не создано, — система принимает за конец работы и убивает процесс без крэша
        // и без логов, вместе с охраной. Резидентность объявляем явно.
        ProcessInfo.processInfo.disableAutomaticTermination("охрана целей должна работать постоянно")
        ProcessInfo.processInfo.disableSuddenTermination()

        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stopForTermination()
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
