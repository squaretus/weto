import Foundation

/// Единственное место, которое решает, что делать с найденным обновлением.
/// Чистая функция: и приложение, и тесты получают один и тот же ответ.
public enum UpdatePolicy {

    public enum Outcome: Equatable, Sendable {
        /// Ни окна, ни баннера: версия пропущена, отложена или не новее текущей.
        case silent
        case prompt
        case install
    }

    /// Дальше этого срока сохранённое напоминание считается испорченным:
    /// перевод системных часов назад иначе запер бы обновления надолго.
    public static let maximumRemindInterval: TimeInterval = RemindInterval.sixHours.rawValue

    public static func decide(
        latest: UpdateInfo,
        deferral: UpdateDeferral,
        now: Date
    ) -> Outcome {
        guard latest.isNewer else { return .silent }
        if deferral.isAutoInstallEnabled { return .install }
        if deferral.skippedVersion == latest.latestVersion { return .silent }
        if let remindAt = deferral.remindAt,
           remindAt > now,
           remindAt <= now.addingTimeInterval(maximumRemindInterval) {
            return .silent
        }
        return .prompt
    }
}
