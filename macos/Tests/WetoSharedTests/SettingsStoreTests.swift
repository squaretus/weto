import XCTest
@testable import WetoShared
import WetoCore
import WetoSystem

final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    func read(account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[account]
    }

    func write(_ value: String?, account: String) -> Result<Void, SecretStoreError> {
        lock.lock(); defer { lock.unlock() }
        storage[account] = value
        return .success(())
    }
}

final class FailingSecretStore: SecretStoring, @unchecked Sendable {
    func read(account: String) -> String? { nil }

    func write(_ value: String?, account: String) -> Result<Void, SecretStoreError> {
        .failure(.keychain(errSecAuthFailed))
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

        XCTAssertTrue(makeStore().isEnabled)
    }

    func test_theme_is_dark_by_default_and_survives_restart() {
        XCTAssertEqual(makeStore().appTheme, .dark)

        let first = makeStore()
        first.appTheme = .light
        XCTAssertEqual(makeStore().appTheme, .light)
    }

    /// Частота опроса больше не настройка: опрос системы бесплатный, а платит
    /// за частоту расписание гео, и крутить его пользователю незачем.
    func test_polling_is_a_constant_not_a_setting() {
        XCTAssertEqual(Constants.tickIntervalSeconds, 1)
        XCTAssertEqual(Constants.geoProbeIntervalSeconds, 5)
    }

    func test_enabled_guard_without_targets_is_harmless() {

        let store = makeStore()
        XCTAssertFalse(store.guardConfig.hasTargets)
        XCTAssertEqual(
            GuardPolicy.decideLocal(isEnabled: true, vpn: .notRunning, config: store.guardConfig),
            .safe
        )
    }

    func test_nothing_is_preconfigured_out_of_the_box() {
        let store = makeStore()
        XCTAssertNil(store.vpnAppRule)
        XCTAssertTrue(store.targets.isEmpty)

        XCTAssertTrue(store.blockedCountryCodes.isEmpty)
    }

    func test_no_preconfigured_data_of_any_kind() {
        let store = makeStore()
        XCTAssertTrue(store.targets.isEmpty)
        XCTAssertTrue(store.blockedCountryCodes.isEmpty)
        XCTAssertTrue(store.blockedIPRangeTexts.isEmpty)
        XCTAssertTrue(store.ipinfoToken.isEmpty)
        XCTAssertNil(store.vpnAppRule)
        XCTAssertNil(store.tokenBox.value)
    }

    func test_explicitly_disabled_guard_survives_reload() {

        let first = makeStore()
        first.isEnabled = false
        XCTAssertFalse(SettingsStore(defaults: defaults, secrets: InMemorySecretStore()).isEnabled)
    }

    func test_values_survive_a_new_store_over_same_defaults() {
        let first = makeStore()
        first.isEnabled = true
        first.vpnAppRule = "su.ffg.happ"
        first.targets = ["com.example.a", "com.example.b"]
        first.blockedCountryCodes = ["RU", "BY"]
        first.blockedIPRangeTexts = ["198.51.100.0/22"]

        let second = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        XCTAssertTrue(second.isEnabled)
        XCTAssertEqual(second.vpnAppRule, "su.ffg.happ")
        XCTAssertEqual(second.targets, ["com.example.a", "com.example.b"])
        XCTAssertEqual(second.blockedCountryCodes, ["BY", "RU"])
        XCTAssertEqual(second.blockedIPRangeTexts, ["198.51.100.0/22"])
    }

    func test_country_codes_are_normalized_to_uppercase() {
        let store = makeStore()
        store.blockedCountryCodes = ["ru", "by"]
        XCTAssertEqual(store.blockedCountryCodes, ["BY", "RU"])
    }

    func test_guard_config_reflects_current_settings() {
        let store = makeStore()
        store.vpnAppRule = "su.ffg.happ"
        store.targets = ["com.example.a"]
        store.blockedCountryCodes = ["RU"]
        store.blockedIPRangeTexts = ["10.0.0.0/8", "мусор"]

        let config = store.guardConfig
        XCTAssertEqual(config.vpnAppRule, "su.ffg.happ")
        XCTAssertEqual(config.targets, ["com.example.a"])
        XCTAssertEqual(config.blockedCountries, ["RU"])
        XCTAssertEqual(config.blockedIPRanges.count, 1, "неразобранные строки отбрасываются")
        XCTAssertTrue(config.blockedIPRanges[0].contains("10.1.2.3"))
    }

    func test_token_goes_to_secret_store_not_to_defaults() {
        let secrets = InMemorySecretStore()
        let store = SettingsStore(defaults: defaults, secrets: secrets)
        store.setIPInfoToken("s3cret")

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
        store.setIPInfoToken("s3cret")
        store.setIPInfoToken("")
        XCTAssertNil(secrets.read(account: "token"))
    }

    /// Охрана не должна завершать собственный источник защиты: выбранное
    /// VPN-приложение снимается из целей, иначе первый же вердикт «небезопасно»
    /// закрыл бы клиент и сделал состояние необратимым.
    func test_choosing_a_vpn_app_removes_it_from_the_targets() {
        let store = makeStore()
        store.targets = ["com.example.a", "su.ffg.happ", "com.example.b"]

        store.vpnAppRule = "su.ffg.happ"

        XCTAssertEqual(store.targets, ["com.example.a", "com.example.b"])
        XCTAssertEqual(store.vpnAppRule, "su.ffg.happ")
    }

    func test_blank_vpn_app_rule_is_stored_as_no_choice() {
        let store = makeStore()
        store.vpnAppRule = "   "

        XCTAssertNil(store.vpnAppRule, "пробелы — это не выбор")
    }

    func test_failed_token_write_is_reported_and_not_advertised_as_persisted() {

        let store = SettingsStore(defaults: defaults, secrets: FailingSecretStore())

        XCTAssertEqual(
            store.setIPInfoToken("secret").failureValue,
            .keychainWriteFailed(errSecAuthFailed)
        )
        XCTAssertTrue(store.ipinfoToken.isEmpty, "незаписанный токен не выдаём за сохранённый")
        XCTAssertNil(store.tokenBox.value)
    }

    func test_successful_token_write_reports_success() {
        let store = makeStore()
        XCTAssertTrue(store.setIPInfoToken("s3cret").isSuccess)
        XCTAssertEqual(store.ipinfoToken, "s3cret")
        XCTAssertEqual(store.tokenBox.value, "s3cret")
    }

    func test_country_code_entry_lands_in_country_list() {
        let store = makeStore()

        XCTAssertTrue(store.addBlockedEntry(" ru ").isSuccess)

        XCTAssertEqual(store.blockedCountryCodes, ["RU"])
        XCTAssertTrue(store.blockedIPRangeTexts.isEmpty)
    }

    func test_cidr_entry_lands_in_range_list() {
        let store = makeStore()

        XCTAssertTrue(store.addBlockedEntry("198.51.100.0/24").isSuccess)

        XCTAssertEqual(store.blockedIPRangeTexts, ["198.51.100.0/24"])
    }

    func test_rejects_malformed_blacklist_range() {

        let store = makeStore()

        XCTAssertEqual(store.addBlockedEntry("10.0.0.0/99").failureValue, .invalidEntry)
        XCTAssertEqual(store.addBlockedEntry("совсем не адрес").failureValue, .invalidEntry)
        XCTAssertEqual(store.addBlockedEntry("   ").failureValue, .empty)

        XCTAssertTrue(store.blockedEntries.isEmpty, "мусор не должен попадать в настройки")
    }

    func test_duplicate_blacklist_entry_is_reported() {
        let store = makeStore()
        XCTAssertTrue(store.addBlockedEntry("RU").isSuccess)

        XCTAssertEqual(store.addBlockedEntry("ru").failureValue, .duplicate)
        XCTAssertEqual(store.blockedCountryCodes, ["RU"])
    }

    func test_removing_entry_clears_it_from_both_lists() {
        let store = makeStore()
        _ = store.addBlockedEntry("RU")
        _ = store.addBlockedEntry("198.51.100.0/24")

        store.removeBlockedEntry("RU")
        XCTAssertEqual(store.blockedEntries, ["198.51.100.0/24"])

        store.removeBlockedEntry("198.51.100.0/24")
        XCTAssertTrue(store.blockedEntries.isEmpty)
    }

    func test_token_box_mirrors_current_token() {

        let secrets = InMemorySecretStore()
        secrets.write("saved", account: "token")

        let store = SettingsStore(defaults: defaults, secrets: secrets)
        XCTAssertEqual(store.tokenBox.value, "saved")

        store.setIPInfoToken("updated")
        XCTAssertEqual(store.tokenBox.value, "updated")

        store.setIPInfoToken("")
        XCTAssertNil(store.tokenBox.value)
    }
}
