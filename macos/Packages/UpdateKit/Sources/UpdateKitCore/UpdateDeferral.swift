import Foundation

/// На сколько отложить разговор об обновлении.
public enum RemindInterval: TimeInterval, CaseIterable, Sendable {
    case oneHour = 3600
    case threeHours = 10800
    case sixHours = 21600
}

/// Всё, что пользователь сказал о показе обновлений и что переживает перезапуск.
public struct UpdateDeferral: Equatable, Sendable {

    /// Версия, о которой просили больше не напоминать. Действует ровно до выхода
    /// версии выше — отдельного способа снять пропуск не требуется.
    public var skippedVersion: String?

    /// Абсолютная дата, раньше которой окно не всплывает.
    public var remindAt: Date?

    public var isAutoInstallEnabled: Bool

    public static let none = UpdateDeferral(
        skippedVersion: nil,
        remindAt: nil,
        isAutoInstallEnabled: false
    )

    public init(skippedVersion: String?, remindAt: Date?, isAutoInstallEnabled: Bool) {
        self.skippedVersion = skippedVersion
        self.remindAt = remindAt
        self.isAutoInstallEnabled = isAutoInstallEnabled
    }
}
