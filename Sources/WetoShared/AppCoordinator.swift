import Foundation
import Observation
import WetoCore
import WetoSystem
import UpdateKitCore
import UpdateKit
import UpdateKitUI
import AppKit
import WetoDesign

@Observable
@MainActor
public final class AppCoordinator {

    public let settings: SettingsStore
    public let eventLog: EventLogStore
    public let guardVM: GuardVM
    public let update: UpdateController

    /// Окно обновления держится координатором: контроллер знает только о флаге
    /// показа, а чем именно рисуется окно — дело приложения.
    @ObservationIgnored public private(set) var updateWindow: UpdateWindowPresenter?

    public let launchAgent: LaunchAgentManaging = LaunchAgentController()
    public let maintenance = Maintenance()

    public init() {

        let settings = SettingsStore()
        let eventLog = EventLogStore()
        self.settings = settings
        self.eventLog = eventLog

        // Механизм обновления собирается из конфигурации проекта: сам пакет
        // не знает ни адреса репозитория, ни имени сервиса демона.
        self.update = UpdateController(
            configuration: WetoUpdate.configuration,
            strings: UpdateStrings(appName: WetoUpdate.configuration.appDisplayName),
            currentVersion: Constants.appVersion,
            fetcher: URLSessionReleaseFetcher(),
            installer: HelperUpdateInstaller(configuration: WetoUpdate.configuration),
            store: UserDefaultsUpdateStore(suiteName: WetoUpdate.configuration.defaultsSuite),
            opener: SystemURLOpener()
        )

        self.guardVM = GuardVM(
            settings: settings,
            eventLog: eventLog,
            snapshotReader: NetworkSnapshotReader(),
            geoProbe: GeoProbe(
                fetcher: URLSessionHTTPFetcher(),
                confirmationFetcher: URLSessionHTTPFetcher(
                    timeout: Constants.geoConfirmationTimeoutSeconds
                ),
                token: { [box = settings.tokenBox] in box.value }
            ),
            locator: ProcessRegistry(),
            killer: ProcessKiller(),
            notifier: UserNotificationKillNotifier(),
            events: NetworkEventSource(),
            launchAgent: LaunchAgentController()
        )

        self.updateWindow = UpdateWindowPresenter(controller: update) { [settings] in
            WetoUpdateTheme.make(for: settings.appTheme)
        }
    }

    /// Приложение показывается в Dock, пока открыто окно настроек или обновления.
    @ObservationIgnored public let dockPresence = DockPresence()

    /// Иконка приложения следует теме: её видят диалоги `NSAlert`, окно обновления
    /// и переключатель приложений. Вызывается на старте и при смене темы.
    public func applyAppIcon() {
        guard let icon = WetoAppIcon.nsImage(for: settings.appTheme.colorScheme) else { return }
        NSApplication.shared.applicationIconImage = icon
    }

    public func start() {
        UserNotificationKillNotifier.requestAuthorization()
        applyAppIcon()
        dockPresence.start()
        guardVM.start()
        update.start()
    }

    /// Останавливает всё, что владеет задачами: и цикл охраны, и проверку обновлений.
    /// Цикл обновлений раньше жил до конца процесса, потому что его задачу никто не хранил.
    public func stopForTermination() {
        dockPresence.stop()
        guardVM.stop()
        update.stop()
    }
}
