import XCTest
@testable import WetoShared
import WetoCore
import WetoSystem

/// Фейк секретного хранилища — Keychain не трогаем в тестах настроек.
final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    func read(account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[account]
    }

    @discardableResult
    func write(_ value: String?, account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        storage[account] = value
        return true
    }
}

@MainActor
final class SettingsStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "com.weto.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    private func makeStore() -> SettingsStore {
        SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
    }

    func test_guard_is_enabled_out_of_the_box() {
        // Сторожевое приложение, которое надо не забыть включить, бесполезно.
        XCTAssertTrue(makeStore().isEnabled)
    }

    func test_enabled_guard_without_targets_is_harmless() {
        // Включённая охрана без целей не должна ничего завершать —
        // именно это делает безопасным умолчание «включено».
        let store = makeStore()
        XCTAssertFalse(store.guardConfig.hasTargets)
        XCTAssertEqual(
            GuardPolicy.decideLocal(isEnabled: true, vpn: .down, config: store.guardConfig),
            .safe
        )
    }

    func test_remaining_defaults_are_empty() {
        let store = makeStore()
        XCTAssertNil(store.vpnServiceName)
        XCTAssertTrue(store.targets.isEmpty)
        
        XCTAssertEqual(store.blockedCountryCodes, ["RU"])
        XCTAssertEqual(store.pollIntervalSeconds, 5)
    }

    func test_explicitly_disabled_guard_survives_reload() {
        // Явное «выключено» не должно перетираться умолчанием при перезапуске.
        let first = makeStore()
        first.isEnabled = false
        XCTAssertFalse(SettingsStore(defaults: defaults, secrets: InMemorySecretStore()).isEnabled)
    }

    func test_values_survive_a_new_store_over_same_defaults() {
        let first = makeStore()
        first.isEnabled = true
        first.vpnServiceName = "Happ"
        first.targets = ["com.example.a", "com.example.b"]
        first.blockedCountryCodes = ["RU", "BY"]
        first.blockedIPRangeTexts = ["198.51.100.0/22"]
        first.pollIntervalSeconds = 15

        let second = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        XCTAssertTrue(second.isEnabled)
        XCTAssertEqual(second.vpnServiceName, "Happ")
        XCTAssertEqual(second.targets, ["com.example.a", "com.example.b"])
        XCTAssertEqual(second.blockedCountryCodes, ["BY", "RU"])
        XCTAssertEqual(second.blockedIPRangeTexts, ["198.51.100.0/22"])
        XCTAssertEqual(second.pollIntervalSeconds, 15)
    }

    func test_country_codes_are_normalized_to_uppercase() {
        let store = makeStore()
        store.blockedCountryCodes = ["ru", "by"]
        XCTAssertEqual(store.blockedCountryCodes, ["BY", "RU"])
    }

    func test_guard_config_reflects_current_settings() {
        let store = makeStore()
        store.vpnServiceName = "Happ"
        store.targets = ["com.example.a"]
        store.blockedCountryCodes = ["RU"]
        store.blockedIPRangeTexts = ["10.0.0.0/8", "мусор"]

        let config = store.guardConfig
        XCTAssertEqual(config.vpnServiceName, "Happ")
        XCTAssertEqual(config.targets, ["com.example.a"])
        XCTAssertEqual(config.blockedCountries, ["RU"])
        XCTAssertEqual(config.blockedIPRanges.count, 1, "неразобранные строки отбрасываются")
        XCTAssertTrue(config.blockedIPRanges[0].contains("10.1.2.3"))
    }

    func test_token_goes_to_secret_store_not_to_defaults() {
        let secrets = InMemorySecretStore()
        let store = SettingsStore(defaults: defaults, secrets: secrets)
        store.ipinfoToken = "s3cret"

        XCTAssertEqual(store.ipinfoToken, "s3cret")
        XCTAssertEqual(secrets.read(account: "token"), "s3cret")
        let plist = defaults.dictionaryRepresentation()
        XCTAssertFalse(
            plist.values.contains { ($0 as? String) == "s3cret" },
            "токен просочился в UserDefaults"
        )
    }

    func test_clearing_token_removes_it_from_secret_store() {
        let secrets = InMemorySecretStore()
        let store = SettingsStore(defaults: defaults, secrets: secrets)
        store.ipinfoToken = "s3cret"
        store.ipinfoToken = ""
        XCTAssertNil(secrets.read(account: "token"))
    }

    func test_token_box_mirrors_current_token() {
        // Коробку читает GeoProbe вне главного актора — она обязана быть
        // синхронизирована и при загрузке, и при изменении.
        let secrets = InMemorySecretStore()
        secrets.write("saved", account: "token")

        let store = SettingsStore(defaults: defaults, secrets: secrets)
        XCTAssertEqual(store.tokenBox.value, "saved")

        store.ipinfoToken = "updated"
        XCTAssertEqual(store.tokenBox.value, "updated")

        store.ipinfoToken = ""
        XCTAssertNil(store.tokenBox.value)
    }
}
