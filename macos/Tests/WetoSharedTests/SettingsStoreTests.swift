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

    func test_pause_ceiling_defaults_to_one_minute_on_a_fresh_install() {
        XCTAssertEqual(makeStore().pauseCeiling, .oneMinute)
    }

    func test_pause_ceiling_survives_a_restart() {
        makeStore().pauseCeiling = .fiveMinutes
        XCTAssertEqual(makeStore().pauseCeiling, .fiveMinutes)
        XCTAssertEqual(defaults.integer(forKey: "pauseCeilingSeconds"), 300)
    }

    func test_an_unknown_stored_pause_ceiling_reads_as_one_minute() {
        defaults.set(42, forKey: "pauseCeilingSeconds")
        XCTAssertEqual(makeStore().pauseCeiling, .oneMinute)
    }

    /// Потолок решения политики не меняет: «правкой настроек» для охраны
    /// он не является и пробу не просит.
    func test_changing_the_pause_ceiling_is_not_a_guard_configuration_change() {
        let store = makeStore()
        var guardChanges: [GuardConfigurationChange] = []
        var ceilings: [PauseCeiling] = []
        store.onGuardConfigurationChange { guardChanges.append($0) }
        store.onPauseCeilingChange { ceilings.append($0) }

        store.pauseCeiling = .tenMinutes

        XCTAssertTrue(guardChanges.isEmpty)
        XCTAssertEqual(ceilings, [.tenMinutes])
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

    // MARK: - Белый список

    func test_allowed_country_entry_is_normalised_and_stored() {
        let store = makeStore()

        XCTAssertTrue(store.addAllowedEntry(" nl ").isSuccess)

        XCTAssertEqual(store.allowedCountryCodes, ["NL"])
        XCTAssertTrue(store.allowedIPRangeTexts.isEmpty)
        XCTAssertTrue(store.blockedEntries.isEmpty, "белый список не должен течь в чёрный")
    }

    func test_allowed_cidr_entry_lands_in_range_list() {
        let store = makeStore()

        XCTAssertTrue(store.addAllowedEntry("198.51.100.0/24").isSuccess)

        XCTAssertEqual(store.allowedIPRangeTexts, ["198.51.100.0/24"])
    }

    func test_rejects_malformed_allowed_entry() {
        let store = makeStore()

        XCTAssertEqual(store.addAllowedEntry("10.0.0.0/99").failureValue, .invalidEntry)
        XCTAssertEqual(store.addAllowedEntry("   ").failureValue, .empty)

        XCTAssertTrue(store.allowedEntries.isEmpty, "мусор не должен попадать в настройки")
    }

    func test_duplicate_allowed_entry_is_reported() {
        let store = makeStore()
        XCTAssertTrue(store.addAllowedEntry("NL").isSuccess)

        XCTAssertEqual(store.addAllowedEntry("nl").failureValue, .duplicate)
        XCTAssertEqual(store.allowedCountryCodes, ["NL"])
    }

    func test_removing_allowed_entry_clears_it_from_both_lists() {
        let store = makeStore()
        _ = store.addAllowedEntry("NL")
        _ = store.addAllowedEntry("198.51.100.0/24")

        store.removeAllowedEntry("NL")
        XCTAssertEqual(store.allowedEntries, ["198.51.100.0/24"])

        store.removeAllowedEntry("198.51.100.0/24")
        XCTAssertTrue(store.allowedEntries.isEmpty)
    }

    /// Одна и та же запись в обоих списках — допустимый ввод: приоритет
    /// задаёт политика, а не поле ввода.
    func test_the_same_entry_may_live_in_both_lists() {
        let store = makeStore()

        XCTAssertTrue(store.addBlockedEntry("NL").isSuccess)
        XCTAssertTrue(store.addAllowedEntry("NL").isSuccess)

        XCTAssertEqual(store.blockedEntries, ["NL"])
        XCTAssertEqual(store.allowedEntries, ["NL"])
    }

    func test_whitelist_survives_a_restart_of_the_store() {
        let secrets = InMemorySecretStore()
        let store = SettingsStore(defaults: defaults, secrets: secrets)
        _ = store.addAllowedEntry("NL")
        _ = store.addAllowedEntry("198.51.100.0/24")

        let reopened = SettingsStore(defaults: defaults, secrets: secrets)

        XCTAssertEqual(reopened.allowedEntries, ["NL", "198.51.100.0/24"])
    }

    /// Ранее сохранённые установки whitelist не знают — и обязаны заводиться
    /// с пустым, а не падать и не терять чёрный список.
    func test_settings_saved_before_the_whitelist_open_with_an_empty_one() {
        defaults.set(["RU"], forKey: "blockedCountryCodes")

        let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())

        XCTAssertEqual(store.blockedEntries, ["RU"])
        XCTAssertTrue(store.allowedEntries.isEmpty)
        XCTAssertTrue(store.guardConfig.allowedCountries.isEmpty)
    }

    func test_guard_config_carries_the_whitelist() {
        let store = makeStore()
        _ = store.addAllowedEntry("NL")
        _ = store.addAllowedEntry("198.51.100.0/24")

        XCTAssertEqual(store.guardConfig.allowedCountries, ["NL"])
        XCTAssertEqual(store.guardConfig.allowedIPRanges.map(\.text), ["198.51.100.0/24"])
    }

    // MARK: - Туннель терминальной версии

    func test_choosing_a_tunnel_drops_the_vpn_app() {
        let store = makeStore()
        store.vpnAppRule = "su.ffg.happ"
        var fields: [GuardConfigurationChange.Field] = []
        store.onGuardConfigurationChange { fields.append($0.field) }

        store.vpnTunnel = "wg0"

        XCTAssertEqual(store.vpnTunnel, "wg0")
        XCTAssertNil(store.vpnAppRule)
        XCTAssertEqual(store.guardConfig.vpnTunnel, "wg0")
        XCTAssertNil(store.guardConfig.vpnAppRule)
        XCTAssertEqual(fields, [.vpnApp, .vpnTunnel])
    }

    func test_choosing_a_vpn_app_drops_the_tunnel() {
        let store = makeStore()
        store.vpnTunnel = "wg0"

        store.vpnAppRule = "su.ffg.happ"

        XCTAssertNil(store.vpnTunnel)
        XCTAssertEqual(store.vpnAppRule, "su.ffg.happ")
        XCTAssertNil(makeStore().vpnTunnel, "снятие записано в набор, а не только в память")
    }

    func test_the_tunnel_survives_a_restart_and_blank_clears_it() {
        makeStore().vpnTunnel = "  utun6 "
        XCTAssertEqual(makeStore().vpnTunnel, "utun6")

        makeStore().vpnTunnel = " "
        XCTAssertNil(makeStore().vpnTunnel)
    }

    /// Окно приложения туннель не задаёт: ключа нет — туннеля нет.
    func test_no_tunnel_out_of_the_box() {
        XCTAssertNil(makeStore().vpnTunnel)
        XCTAssertNil(makeStore().guardConfig.vpnTunnel)
    }

    // MARK: - Перечитывание набора

    /// Настройки правит одна копия, охраняет другая: работающая охрана обязана
    /// подхватить правку, и подписчики слышат ровно отличающиеся поля.
    func test_reload_applies_only_the_fields_another_store_changed() {
        let secrets = InMemorySecretStore()
        let running = SettingsStore(defaults: defaults, secrets: secrets)
        running.targets = ["claude"]
        running.blockedCountryCodes = ["RU"]
        var heard: [GuardConfigurationChange.Field] = []
        running.onGuardConfigurationChange { heard.append($0.field) }

        let editor = SettingsStore(defaults: defaults, secrets: secrets)
        editor.targets = ["claude", "codex"]
        editor.vpnTunnel = "wg0"

        let changed = running.reloadFromDefaults()

        XCTAssertEqual(running.targets, ["claude", "codex"])
        XCTAssertEqual(running.vpnTunnel, "wg0")
        XCTAssertEqual(running.blockedCountryCodes, ["RU"])
        XCTAssertEqual(heard, [.targets, .vpnTunnel])
        XCTAssertEqual(changed, [.targets, .vpnTunnel])
    }

    func test_reload_without_changes_says_nothing() {
        let store = makeStore()
        store.targets = ["claude"]
        store.vpnTunnel = "wg0"
        _ = store.addAllowedEntry("NL")
        var heard: [GuardConfigurationChange.Field] = []
        store.onGuardConfigurationChange { heard.append($0.field) }

        XCTAssertTrue(store.reloadFromDefaults().isEmpty)
        XCTAssertTrue(heard.isEmpty, "совпадающие поля не поднимают ревизию и не просят пробу")
    }

    /// Выбор VPN сменил сторону во второй копии: перечитывание не имеет права
    /// оставить обе стороны выбранными — и не имеет права стереть прочитанное.
    func test_reload_switches_the_vpn_from_app_to_tunnel_and_back() {
        let running = makeStore()
        running.vpnAppRule = "su.ffg.happ"
        let editor = makeStore()

        editor.vpnTunnel = "wg0"
        running.reloadFromDefaults()
        XCTAssertNil(running.vpnAppRule)
        XCTAssertEqual(running.vpnTunnel, "wg0")

        editor.vpnAppRule = "su.ffg.happ"
        running.reloadFromDefaults()
        XCTAssertEqual(running.vpnAppRule, "su.ffg.happ")
        XCTAssertNil(running.vpnTunnel)
    }

    func test_reload_picks_up_the_pause_ceiling_without_a_configuration_change() {
        let running = makeStore()
        var heard: [GuardConfigurationChange.Field] = []
        var ceilings: [PauseCeiling] = []
        running.onGuardConfigurationChange { heard.append($0.field) }
        running.onPauseCeilingChange { ceilings.append($0) }

        makeStore().pauseCeiling = .fiveMinutes
        running.reloadFromDefaults()

        XCTAssertEqual(running.pauseCeiling, .fiveMinutes)
        XCTAssertEqual(ceilings, [.fiveMinutes])
        XCTAssertTrue(heard.isEmpty)
    }

    func test_reload_picks_up_a_token_written_by_another_copy() {
        let secrets = InMemorySecretStore()
        let running = SettingsStore(defaults: defaults, secrets: secrets)
        var heard: [GuardConfigurationChange.Field] = []
        running.onGuardConfigurationChange { heard.append($0.field) }

        SettingsStore(defaults: defaults, secrets: secrets).setIPInfoToken("abc")
        running.reloadFromDefaults()

        XCTAssertEqual(running.ipinfoToken, "abc")
        XCTAssertEqual(running.tokenBox.value, "abc")
        XCTAssertEqual(heard, [.ipinfoToken])
    }

    /// Перечитанное назад не пишется: запись прочитанного затёрла бы правку второй
    /// копии, сделанную между чтением и записью.
    func test_reload_does_not_write_back_what_it_read() {
        let running = makeStore()
        makeStore().targets = ["claude"]
        let observer = KeyWriteObserver(defaults: defaults, key: "targets")

        running.reloadFromDefaults()

        XCTAssertEqual(running.targets, ["claude"])
        XCTAssertEqual(observer.writes, 0)

        // Наблюдатель видит запись: обычная правка после перечитывания пишется как всегда.
        running.targets = ["claude", "codex"]
        XCTAssertEqual(observer.writes, 1)
        withExtendedLifetime(observer) {}
    }
}

/// Считает записи ключа в набор: `UserDefaults` шлёт KVO на каждую `set`.
private final class KeyWriteObserver: NSObject {
    private let defaults: UserDefaults
    private let key: String
    private(set) var writes = 0

    init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
        super.init()
        defaults.addObserver(self, forKeyPath: key, options: [.new], context: nil)
    }

    deinit { defaults.removeObserver(self, forKeyPath: key) }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        writes += 1
    }
}
