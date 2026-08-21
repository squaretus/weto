import XCTest
import AppKit
@testable import WetoSystem

final class NetworkEventSourceTests: XCTestCase {

    func test_start_delivers_initial_network_path_event() {

        let source = NetworkEventSource()
        let received = expectation(description: "получено событие о сетевом пути")
        received.assertForOverFulfill = false

        source.start { trigger in
            if case .networkPath = trigger { received.fulfill() }
        }
        defer { source.stop() }

        wait(for: [received], timeout: 5)
    }

    func test_wake_notification_produces_trigger() {
        let source = NetworkEventSource()
        let received = expectation(description: "получено событие о пробуждении")
        received.assertForOverFulfill = false

        source.start { trigger in
            if case .wake = trigger { received.fulfill() }
        }
        defer { source.stop() }

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification, object: nil
        )

        wait(for: [received], timeout: 5)
    }

    func test_app_launch_notification_carries_bundle_id() throws {

        guard let sample = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier != nil }),
              let expectedID = sample.bundleIdentifier
        else { throw XCTSkip("нет запущенных приложений с bundle ID") }

        let source = NetworkEventSource()
        let received = expectation(description: "получен bundle ID запущенного приложения")
        received.assertForOverFulfill = false

        source.start { trigger in
            if case .appLaunched(let bundleID) = trigger, bundleID == expectedID {
                received.fulfill()
            }
        }
        defer { source.stop() }

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: sample]
        )

        wait(for: [received], timeout: 5)
    }

    /// Подписки на завершение приложения раньше не было вовсе: уход VPN-клиента
    /// замечался только следующим тиком. Для килл-свитча это самое важное известие.
    func test_app_termination_notification_carries_bundle_id() throws {
        guard let sample = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier != nil }),
              let expectedID = sample.bundleIdentifier
        else { throw XCTSkip("нет запущенных приложений с bundle ID") }

        let source = NetworkEventSource()
        let received = expectation(description: "получен bundle ID закрытого приложения")
        received.assertForOverFulfill = false

        source.start { trigger in
            if case .appTerminated(let bundleID) = trigger, bundleID == expectedID {
                received.fulfill()
            }
        }
        defer { source.stop() }

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: sample]
        )

        wait(for: [received], timeout: 5)
    }

    func test_termination_notification_without_payload_is_ignored() {
        let source = NetworkEventSource()
        let unexpected = expectation(description: "триггер завершения не должен прийти")
        unexpected.isInverted = true

        source.start { trigger in
            if case .appTerminated = trigger { unexpected.fulfill() }
        }
        defer { source.stop() }

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didTerminateApplicationNotification, object: nil
        )

        wait(for: [unexpected], timeout: 1)
    }

    /// Маршрутный сокет открывается и закрывается вместе с источником.
    /// Подъём туннеля добавляет маршруты сотнями сообщений, и каждое из них
    /// нельзя превращать в обход процессов, поэтому пачка схлопывается — но
    /// живую пачку маршрутов без прав root в тесте не создать, поэтому здесь
    /// проверяется только то, что подписка не роняет источник и снимается чисто.
    func test_route_subscription_starts_and_stops_cleanly() {
        let source = NetworkEventSource()
        let started = expectation(description: "источник запустился")
        started.assertForOverFulfill = false

        source.start { _ in started.fulfill() }
        wait(for: [started], timeout: 5)

        source.stop()
        source.stop()
    }

    func test_launch_notification_without_payload_is_ignored() {
        let source = NetworkEventSource()
        let unexpected = expectation(description: "триггер запуска не должен прийти")
        unexpected.isInverted = true

        source.start { trigger in
            if case .appLaunched = trigger { unexpected.fulfill() }
        }
        defer { source.stop() }

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didLaunchApplicationNotification, object: nil
        )

        wait(for: [unexpected], timeout: 1)
    }

    func test_stop_silences_further_events() {
        let source = NetworkEventSource()
        let lock = NSLock()
        var count = 0

        source.start { _ in
            lock.lock(); count += 1; lock.unlock()
        }
        Thread.sleep(forTimeInterval: 0.5)
        source.stop()

        lock.lock(); let afterStop = count; lock.unlock()

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification, object: nil
        )
        Thread.sleep(forTimeInterval: 0.5)

        lock.lock(); let final = count; lock.unlock()
        XCTAssertEqual(afterStop, final, "события продолжают приходить после stop()")
    }
}
