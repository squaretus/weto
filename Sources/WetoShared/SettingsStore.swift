import Foundation
import Observation
import WetoCore
import WetoSystem

/// Настройки приложения.
///
/// Внутри `@Observable` используется `UserDefaults` напрямую, а не `@AppStorage`:
/// последний не работает вне `View` и ломает наблюдение в VM-слое.
///
/// По умолчанию охрана выключена: приложение сразу после установки не должно
/// начать убивать процессы, пока пользователь не выбрал цели и VPN.
@Observable
@MainActor
public final class SettingsStore {

    private enum Key {
        static let isEnabled = "isEnabled"
        static let vpnServiceName = "vpnServiceName"
        static let targets = "targets"
        /// Ключи предыдущей раскладки, когда приложения и команды жили раздельно.
        /// Читаются один раз при миграции.
        static let legacyBundleIDs = "targetBundleIDs"
        static let legacyExecutables = "targetExecutables"
        static let blockedCountryCodes = "blockedCountryCodes"
        static let blockedIPRangeTexts = "blockedIPRangeTexts"
        static let pollIntervalSeconds = "pollIntervalSeconds"
    }

    private static let tokenAccount = "token"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secrets: SecretStoring

    /// Токен нужен `GeoProbe`, который работает вне главного актора.
    /// Читать `@MainActor`-свойство оттуда нельзя, поэтому значение
    /// дублируется в потокобезопасную коробку.
    @ObservationIgnored public let tokenBox = TokenBox()

    public init(defaults: UserDefaults, secrets: SecretStoring) {
        self.defaults = defaults
        self.secrets = secrets
        // Охрана включена по умолчанию: сторожевое приложение, которое надо
        // не забыть включить, бесполезно. Пока цели не заданы, включённая
        // охрана всё равно ничего не делает.
        self._isEnabled = defaults.object(forKey: Key.isEnabled) as? Bool ?? true
        self._vpnServiceName = defaults.string(forKey: Key.vpnServiceName)
        self._targets = Self.loadTargets(from: defaults)
        self._blockedCountryCodes = defaults.stringArray(forKey: Key.blockedCountryCodes)
            ?? Constants.defaultBlockedCountries.sorted()
        self._blockedIPRangeTexts = defaults.stringArray(forKey: Key.blockedIPRangeTexts) ?? []
        let interval = defaults.double(forKey: Key.pollIntervalSeconds)
        self._pollIntervalSeconds = interval > 0 ? interval : Constants.defaultPollIntervalSeconds
        self._ipinfoToken = secrets.read(account: Self.tokenAccount) ?? ""
        self.tokenBox.value = _ipinfoToken.isEmpty ? nil : _ipinfoToken
    }

    /// Удобный конструктор для приложения: общий suite и Keychain.
    public convenience init() {
        self.init(
            defaults: UserDefaults(suiteName: Constants.userDefaultsSuite) ?? .standard,
            secrets: KeychainStore(service: Constants.keychainService)
        )
    }

    // MARK: - Свойства

    private var _isEnabled: Bool
    public var isEnabled: Bool {
        get { _isEnabled }
        set { _isEnabled = newValue; defaults.set(newValue, forKey: Key.isEnabled) }
    }

    private var _vpnServiceName: String?
    public var vpnServiceName: String? {
        get { _vpnServiceName }
        set { _vpnServiceName = newValue; defaults.set(newValue, forKey: Key.vpnServiceName) }
    }

    private var _targets: [String]
    /// Цели одним списком: bundle ID приложения, путь к `.app`, имя команды
    /// или путь к бинарнику. Что именно это такое, разбирает `TargetResolver`.
    public var targets: [String] {
        get { _targets }
        set { _targets = newValue; defaults.set(newValue, forKey: Key.targets) }
    }

    /// Разбор старой раскладки, где приложения и команды хранились раздельно.
    /// Нужен один раз: после первой записи `targets` старые ключи не читаются.
    private static func loadTargets(from defaults: UserDefaults) -> [String] {
        if let stored = defaults.stringArray(forKey: Key.targets) { return stored }

        let legacy = (defaults.stringArray(forKey: Key.legacyBundleIDs) ?? [])
            + (defaults.stringArray(forKey: Key.legacyExecutables) ?? [])
        if !legacy.isEmpty { defaults.set(legacy, forKey: Key.targets) }
        return legacy
    }

    private var _blockedCountryCodes: [String]
    /// Всегда в верхнем регистре и отсортированы — так их проще сравнивать и показывать.
    public var blockedCountryCodes: [String] {
        get { _blockedCountryCodes }
        set {
            let normalized = Array(Set(newValue.map { $0.uppercased() })).sorted()
            _blockedCountryCodes = normalized
            defaults.set(normalized, forKey: Key.blockedCountryCodes)
        }
    }

    private var _blockedIPRangeTexts: [String]
    public var blockedIPRangeTexts: [String] {
        get { _blockedIPRangeTexts }
        set { _blockedIPRangeTexts = newValue; defaults.set(newValue, forKey: Key.blockedIPRangeTexts) }
    }

    private var _pollIntervalSeconds: TimeInterval
    public var pollIntervalSeconds: TimeInterval {
        get { _pollIntervalSeconds }
        set { _pollIntervalSeconds = newValue; defaults.set(newValue, forKey: Key.pollIntervalSeconds) }
    }

    private var _ipinfoToken: String
    public var ipinfoToken: String {
        get { _ipinfoToken }
        set {
            _ipinfoToken = newValue
            secrets.write(newValue.isEmpty ? nil : newValue, account: Self.tokenAccount)
            tokenBox.value = newValue.isEmpty ? nil : newValue
        }
    }

    // MARK: - Производное

    /// Снимок настроек в том виде, в каком его потребляет `GuardPolicy`.
    /// Неразобранные строки CIDR молча отбрасываются: UI подсвечивает их
    /// при вводе, а политика обязана работать с тем, что есть.
    public var guardConfig: GuardConfig {
        GuardConfig(
            vpnServiceName: vpnServiceName,
            blockedCountries: Set(blockedCountryCodes),
            blockedIPRanges: blockedIPRangeTexts.compactMap(IPRange.init),
            targets: targets
        )
    }
}
