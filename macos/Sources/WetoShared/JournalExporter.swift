import Foundation
import WetoCore

/// Сборка выгрузки журнала.
///
/// Отдельно от хранилища: журнал знает, как хранить записи, а выгрузка — что ещё
/// положить рядом, чтобы по файлу можно было разобраться без машины пользователя.
@MainActor
public enum JournalExporter {

    public static func make(
        settings: SettingsStore,
        events: [KillEvent],
        checks: [CheckEvent] = [],
        at moment: Date = Date(),
        osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) -> JournalExport {
        let config = settings.guardConfig

        return JournalExport(
            exportedAt: moment,
            app: JournalExport.App(
                version: Constants.appVersion,
                platform: "macOS",
                osVersion: osVersion
            ),
            settings: JournalExport.Settings(
                isEnabled: settings.isEnabled,
                vpnAppRule: config.vpnAppRule,
                targets: config.targets,
                blockedCountries: Array(config.blockedCountries),
                blockedIPRanges: config.blockedIPRanges.map(\.text),
                allowedCountries: Array(config.allowedCountries),
                allowedIPRanges: config.allowedIPRanges.map(\.text),
                hasIPInfoToken: !settings.ipinfoToken.isEmpty
            ),
            events: events,
            checks: checks
        )
    }
}
