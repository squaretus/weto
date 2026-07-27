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
