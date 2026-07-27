import Foundation
import UserNotifications

/// Граница системы: уведомление пользователя о срабатывании.
public protocol KillNotifying: Sendable {
    func notify(reasonText: String, killedCount: Int)
}

/// Системное уведомление.
///
/// Нужно потому, что цель исчезает молча и без объяснения это выглядит как краш.
public struct UserNotificationKillNotifier: KillNotifying {

    public init() {}

    public func notify(reasonText: String, killedCount: Int) {
        // Вне бандла центр уведомлений недоступен и бросает исключение
        // (например, при `swift run` до сборки .app) — молча пропускаем.
        guard Bundle.main.bundleIdentifier != nil else { return }

        let content = UNMutableNotificationContent()
        content.title = "Weto: процессы завершены"
        content.body = "\(reasonText). Завершено процессов: \(killedCount)."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Запрашивается один раз при старте приложения.
    public static func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
