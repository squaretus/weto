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

    /// Как показывать уведомление, пришедшее при активном приложении.
    ///
    /// Без делегата macOS гасит такое уведомление молча — считается, что человек
    /// и так смотрит на приложение. Для weto это ровно наоборот: «активно» здесь
    /// значит открытый попап или окно настроек, то есть момент, когда пользователь
    /// смотрит на статус и ждёт объяснений. Уведомления о завершении целей
    /// приходили «через раз» именно поэтому — молчал не weto, молчала система.
    public static let presentationWhileActive: UNNotificationPresentationOptions = [.banner, .sound]

    /// Делегат живёт столько же, сколько процесс: `UNUserNotificationCenter`
    /// держит его слабо, и локальный экземпляр умер бы сразу после `activate()`.
    private static let presenter = Presenter()

    private final class Presenter: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            completionHandler(UserNotificationKillNotifier.presentationWhileActive)
        }
    }

    /// Разрешение и делегат ставятся одним вызовом: порознь их легко развести,
    /// а без делегата разрешение бессмысленно ровно в те моменты, когда weto
    /// на экране.
    public static func activate() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = presenter
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
