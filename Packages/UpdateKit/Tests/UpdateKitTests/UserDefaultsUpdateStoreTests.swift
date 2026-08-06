import XCTest
import UpdateKitCore
@testable import UpdateKit

@MainActor
final class UserDefaultsUpdateStoreTests: XCTestCase {

    private let suite = "com.example.updatekit.tests"

    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func test_deferral_survives_a_new_store() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let store = UserDefaultsUpdateStore(suiteName: suite)

        store.save(UpdateDeferral(skippedVersion: "0.4.2", remindAt: date, isAutoInstallEnabled: true))

        let reopened = UserDefaultsUpdateStore(suiteName: suite).loadDeferral()
        XCTAssertEqual(reopened.skippedVersion, "0.4.2")
        XCTAssertEqual(reopened.remindAt, date)
        XCTAssertTrue(reopened.isAutoInstallEnabled)
    }

    func test_empty_store_defaults_to_no_deferral() {
        XCTAssertEqual(UserDefaultsUpdateStore(suiteName: suite).loadDeferral(), .none)
    }

    func test_last_check_round_trips() {
        let date = Date(timeIntervalSince1970: 1_800_000_100)
        let store = UserDefaultsUpdateStore(suiteName: suite)

        store.saveLastCheck(date)

        XCTAssertEqual(UserDefaultsUpdateStore(suiteName: suite).loadLastCheck(), date)
    }
}
