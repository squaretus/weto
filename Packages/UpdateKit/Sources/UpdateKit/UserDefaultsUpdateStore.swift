import Foundation
import UpdateKitCore

/// Ключи с префиксом `update.`: сюит общий с настройками приложения,
/// и механизм не должен занимать в нём случайные имена.
@MainActor
public final class UserDefaultsUpdateStore: UpdateStateStoring {

    private enum Key {
        static let skippedVersion = "update.skippedVersion"
        static let remindAt = "update.remindAt"
        static let autoInstall = "update.autoInstall"
        static let lastCheckAt = "update.lastCheckAt"
    }

    private let defaults: UserDefaults

    public init(suiteName: String) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    public func loadDeferral() -> UpdateDeferral {
        UpdateDeferral(
            skippedVersion: defaults.string(forKey: Key.skippedVersion),
            remindAt: defaults.object(forKey: Key.remindAt) as? Date,
            isAutoInstallEnabled: defaults.bool(forKey: Key.autoInstall)
        )
    }

    public func save(_ deferral: UpdateDeferral) {
        defaults.set(deferral.skippedVersion, forKey: Key.skippedVersion)
        defaults.set(deferral.remindAt, forKey: Key.remindAt)
        defaults.set(deferral.isAutoInstallEnabled, forKey: Key.autoInstall)
    }

    public func loadLastCheck() -> Date? {
        defaults.object(forKey: Key.lastCheckAt) as? Date
    }

    public func saveLastCheck(_ date: Date) {
        defaults.set(date, forKey: Key.lastCheckAt)
    }
}
