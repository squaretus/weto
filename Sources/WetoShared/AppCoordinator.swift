import Foundation
import Observation
import WetoCore
import WetoSystem

@Observable
@MainActor
public final class AppCoordinator {

    public let settings: SettingsStore
    public let eventLog: EventLogStore
    public let guardVM: GuardVM
    public let update = UpdateVM()

    public init() {

        let settings = SettingsStore()
        let eventLog = EventLogStore()
        self.settings = settings
        self.eventLog = eventLog

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
            events: NetworkEventSource()
        )
    }

    public func start() {
        UserNotificationKillNotifier.requestAuthorization()
        guardVM.start()
        update.startPeriodicCheck()
    }
}
