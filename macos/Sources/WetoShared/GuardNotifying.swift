import Foundation
import UserNotifications

/// Что охрана сообщает пользователю системным уведомлением.
///
/// Две новости, а не одна: завершённые цели и цель, потерявшая терминал под паузой.
/// Вторую без уведомления не заметить вовсе — процесс просто «пропал» из терминала.
public protocol GuardNotifying: Sendable {
    func notifyTerminated(reasonText: String, killedCount: Int)
    /// Терминальная цель ушла в фон по запасному пути паузы: вернуть её пользователю — `fg`.
    func notifyBackgrounded(targetName: String)
}

public struct UserNotificationGuardNotifier: GuardNotifying {

    public static let backgroundedCategory = "com.weto.paused.backgrounded"

    public init() {}

    public func notifyTerminated(reasonText: String, killedCount: Int) {

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

    public func notifyBackgrounded(targetName: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }

        let content = UNMutableNotificationContent()
        content.title = "Weto: \(targetName) вернулся в фон"
        content.body = "Процесс на паузе потерял терминал. Откройте терминал и введите fg."
        content.categoryIdentifier = Self.backgroundedCategory
        content.sound = .default

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    /// Нажатие на уведомление открывает попап: обработчик задаёт приложение (задача 18).
    nonisolated(unsafe) public static var onOpen: (@MainActor @Sendable () -> Void)?

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
            completionHandler(UserNotificationGuardNotifier.presentationWhileActive)
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse,
            withCompletionHandler completionHandler: @escaping () -> Void
        ) {
            Task { @MainActor in UserNotificationGuardNotifier.onOpen?() }
            completionHandler()
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
