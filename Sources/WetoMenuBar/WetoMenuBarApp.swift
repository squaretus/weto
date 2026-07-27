import SwiftUI
import AppKit
import WetoShared

/// Гейт от повторного запуска бинарника напрямую из терминала или отладчика.
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

/// Владелец жизненного цикла охраны.
///
/// Старт живёт здесь, а НЕ на `.task` у содержимого `MenuBarExtra`: при стиле
/// `.window` SwiftUI создаёт содержимое попапа лениво, только при первом клике
/// по иконке. Для сторожевого приложения это означало бы, что защиты нет, пока
/// пользователь не заглянул в меню. Проверено экспериментально: цель выживала
/// при заблокированной стране до открытия попапа.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let coordinator = AppCoordinator()
    private let instanceGuard = SingleInstanceGuard()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard instanceGuard.acquire() else {
            NSApplication.shared.terminate(nil)
            return
        }
        // Приложение живёт только в менюбаре, иконки в Dock у него нет.
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
                .frame(width: 340)
        } label: {
            MenuBarLabel()
                .environment(delegate.coordinator)
        }
        .menuBarExtraStyle(.window)

        Window("Настройки Weto", id: SettingsWindow.identifier) {
            SettingsWindow()
                .environment(delegate.coordinator)
        }
        .defaultSize(width: 560, height: 620)
    }
}
