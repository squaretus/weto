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

    /// Токен активности держит процесс вне App Nap. Отпускать его нельзя:
    /// с концом активности возвращается и throttling таймеров охраны.
    private var activity: NSObjectProtocol?

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

        // App Nap — отдельный механизм от автозавершения, и он душит именно такие
        // процессы: `LSUIElement` без единого окна, вся работа которого — таймеры.
        // Под ним `Task.sleep` коалесцируется, и секундный опрос растягивается
        // на минуты: цель, добавленная или запущенная после закрытия окна, попадала
        // под охрану неизвестно когда — со стороны это выглядело как «пока не
        // перезапустишь weto, цели не подхватываются».
        //
        // Активность держится всё время жизни процесса. Опция без
        // `idleSystemSleepDisabled`: усыплять машину пользователю мы не запрещаем,
        // отказываемся только от throttling самих таймеров.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "охрана целей опрашивает процессы раз в секунду"
        )

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
