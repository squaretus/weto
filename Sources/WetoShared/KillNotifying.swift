import Foundation
import UserNotifications

public protocol KillNotifying: Sendable {
    func notify(reasonText: String, killedCount: Int)
}

public struct UserNotificationKillNotifier: KillNotifying {

    public init() {}

    public func notify(reasonText: String, killedCount: Int) {

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

    public static func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
