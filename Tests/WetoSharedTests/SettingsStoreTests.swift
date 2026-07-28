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

    func test_poll_interval_options_start_at_five_seconds() {
        XCTAssertEqual(Constants.pollIntervalOptions, [5, 10, 15])
        XCTAssertTrue(Constants.pollIntervalOptions.contains(makeStore().pollIntervalSeconds))
    }

    func test_enabled_guard_without_targets_is_harmless() {

        let store = makeStore()
        XCTAssertFalse(store.guardConfig.hasTargets)
        XCTAssertEqual(
            GuardPolicy.decideLocal(isEnabled: true, vpn: .down, config: store.guardConfig),
            .safe
        )
    }

    func test_nothing_is_preconfigured_out_of_the_box() {
        let store = makeStore()
        XCTAssertNil(store.vpnServiceID)
        XCTAssertTrue(store.targets.isEmpty)

        XCTAssertTrue(store.blockedCountryCodes.isEmpty)
        XCTAssertEqual(store.pollIntervalSeconds, 5)
    }

    func test_no_preconfigured_data_of_any_kind() {
        let store = makeStore()
        XCTAssertTrue(store.targets.isEmpty)
        XCTAssertTrue(store.blockedCountryCodes.isEmpty)
        XCTAssertTrue(store.blockedIPRangeTexts.isEmpty)
        XCTAssertTrue(store.ipinfoToken.isEmpty)
        XCTAssertNil(store.vpnServiceID)
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
        first.vpnServiceID = "BC2D1D42"
        first.targets = ["com.example.a", "com.example.b"]
        first.blockedCountryCodes = ["RU", "BY"]
        first.blockedIPRangeTexts = ["198.51.100.0/22"]
        first.pollIntervalSeconds = 15

        let second = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        XCTAssertTrue(second.isEnabled)
        XCTAssertEqual(second.vpnServiceID, "BC2D1D42")
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
        store.vpnServiceID = "BC2D1D42"
        store.targets = ["com.example.a"]
        store.blockedCountryCodes = ["RU"]
        store.blockedIPRangeTexts = ["10.0.0.0/8", "мусор"]

        let config = store.guardConfig
        XCTAssertEqual(config.vpnServiceID, "BC2D1D42")
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

    private func snapshot(
        services: [NetworkServiceSnapshot] = [
            .init(uuid: "108E2488", name: "Wi-Fi", activeInterface: "en0", isVPN: false),
            .init(uuid: "BC2D1D42", name: "Happ", activeInterface: "utun6", isVPN: true),
        ]
    ) -> NetworkSnapshot {
        NetworkSnapshot(services: services, primaryServiceUUID: "BC2D1D42")
    }

    func test_legacy_vpn_name_migrates_to_the_single_matching_service() {
        defaults.set("Happ", forKey: "vpnServiceName")

        let store = makeStore()
        store.migrateLegacyVPNSelection(in: snapshot())

        XCTAssertEqual(store.vpnServiceID, "BC2D1D42")
        XCTAssertNil(defaults.string(forKey: "vpnServiceName"), "legacy-ключ должен исчезнуть")
    }

    func test_ambiguous_legacy_vpn_name_is_cleared_instead_of_guessed() {

        defaults.set("Happ", forKey: "vpnServiceName")

        let store = makeStore()
        store.migrateLegacyVPNSelection(in: snapshot(services: [
            .init(uuid: "vpn-a", name: "Happ", activeInterface: nil, isVPN: true),
            .init(uuid: "vpn-b", name: "Happ", activeInterface: "utun6", isVPN: true),
        ]))

        XCTAssertNil(store.vpnServiceID)
        XCTAssertNil(defaults.string(forKey: "vpnServiceName"))
    }

    func test_legacy_name_of_a_non_vpn_service_is_cleared() {

        defaults.set("Wi-Fi", forKey: "vpnServiceName")

        let store = makeStore()
        store.migrateLegacyVPNSelection(in: snapshot())

        XCTAssertNil(store.vpnServiceID)
    }

    func test_migration_never_overwrites_an_explicit_service_id() {
        let first = makeStore()
        first.vpnServiceID = "BC2D1D42"
        defaults.set("Wi-Fi", forKey: "vpnServiceName")

        let second = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        second.migrateLegacyVPNSelection(in: snapshot())

        XCTAssertEqual(second.vpnServiceID, "BC2D1D42")
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
