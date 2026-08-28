import XCTest
import UserNotifications
@testable import WetoShared

final class KillNotifyingTests: XCTestCase {

    /// Уведомление обязано показываться и при активном приложении.
    ///
    /// У weto «активно» — это открытый попап или окно настроек, то есть ровно тот
    /// момент, когда пользователь смотрит на статус. macOS по умолчанию гасит
    /// уведомления активного приложения молча, и это выглядело как «weto сообщает
    /// о завершении целей через раз».
    func test_notification_is_shown_even_when_the_app_is_active() {
        let options = UserNotificationKillNotifier.presentationWhileActive

        XCTAssertTrue(options.contains(.banner), "баннер обязан показываться поверх активного приложения")
        XCTAssertTrue(options.contains(.sound), "звук обязан звучать вместе с баннером")
    }
}
