import Foundation
import Observation
import WetoCore
import WetoSystem

public enum AppTheme: String, CaseIterable, Sendable {
    case dark
    case light

    public var title: String {
        switch self {
        case .dark: return "Тёмная"
        case .light: return "Светлая"
        }
    }
}

public enum BlacklistEntryError: Error, Equatable, Sendable {
    case empty
    case invalidEntry
    case duplicate

    public var displayText: String {
        switch self {
        case .empty:
            return "введите код страны, IP-адрес или диапазон"
        case .invalidEntry:
            return "не похоже ни на код страны, ни на IP-адрес или CIDR"
        case .duplicate:
            return "такая запись уже есть в списке"
        }
    }
}

public enum SettingsPersistenceError: Error, Equatable, Sendable {
    case keychainWriteFailed(OSStatus)

    public var displayText: String {
        switch self {
        case .keychainWriteFailed(let status):
            return "не удалось сохранить токен в связку ключей (ошибка \(status))"
        }
    }
}

/// Изменение настройки, от которой зависит решение охраны. Публикуется синхронно
/// на главном акторе: цель, добавленная при небезопасном состоянии, обязана быть
/// завершена сразу, а не через тик поллинга.
public struct GuardConfigurationChange: Equatable, Sendable {
    public enum Field: Equatable, Sendable {
        case guardEnabled
        case targets
        case vpnApp
        case ipinfoToken
        case blacklist
    }

    public let field: Field

    public init(field: Field) {
        self.field = field
    }
}

@Observable
@MainActor
public final class SettingsStore {

    private enum Key {
        static let isEnabled = "isEnabled"
        static let appTheme = "appTheme"
        /// Ключ новый: смысл выбора изменился с «идентификатор туннеля» на «правило
        /// приложения», и переносить прежнее значение нельзя — оно называет `utunN`
        /// или UUID сервиса, а не приложение.
        static let vpnAppRule = "vpnAppRule"
        static let targets = "targets"

        static let legacyBundleIDs = "targetBundleIDs"
        static let legacyExecutables = "targetExecutables"
        static let blockedCountryCodes = "blockedCountryCodes"
        static let blockedIPRangeTexts = "blockedIPRangeTexts"
    }

    private static let tokenAccount = "token"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secrets: SecretStoring

    @ObservationIgnored public let tokenBox = TokenBox()

    @ObservationIgnored
    private var guardChangeHandlers: [(GuardConfigurationChange) -> Void] = []

    public init(defaults: UserDefaults, secrets: SecretStoring) {
        self.defaults = defaults
        self.secrets = secrets

        self._isEnabled = defaults.object(forKey: Key.isEnabled) as? Bool ?? true
        self._appTheme = defaults.string(forKey: Key.appTheme)
            .flatMap(AppTheme.init(rawValue:)) ?? .dark
        self._vpnAppRule = defaults.string(forKey: Key.vpnAppRule)
        self._targets = Self.loadTargets(from: defaults)
        self._blockedCountryCodes = defaults.stringArray(forKey: Key.blockedCountryCodes) ?? []
        self._blockedIPRangeTexts = defaults.stringArray(forKey: Key.blockedIPRangeTexts) ?? []
        self._ipinfoToken = secrets.read(account: Self.tokenAccount) ?? ""
        self.tokenBox.value = _ipinfoToken.isEmpty ? nil : _ipinfoToken
    }

    public convenience init() {
        self.init(
            defaults: UserDefaults(suiteName: Constants.userDefaultsSuite) ?? .standard,
            secrets: KeychainStore(service: Constants.keychainService)
        )
    }

    private var _isEnabled: Bool
    public var isEnabled: Bool {
        get { _isEnabled }
        set {
            _isEnabled = newValue
            defaults.set(newValue, forKey: Key.isEnabled)
            emit(.guardEnabled)
        }
    }

    private var _appTheme: AppTheme
    public var appTheme: AppTheme {
        get { _appTheme }
        set { _appTheme = newValue; defaults.set(newValue.rawValue, forKey: Key.appTheme) }
    }

    private var _vpnAppRule: String?

    /// Выбранное VPN-приложение — тем же правилом, что цели: bundle ID или путь.
    public var vpnAppRule: String? {
        get { _vpnAppRule }
        set {
            let cleaned = newValue?.trimmingCharacters(in: .whitespaces)
            _vpnAppRule = (cleaned?.isEmpty ?? true) ? nil : cleaned
            defaults.set(_vpnAppRule, forKey: Key.vpnAppRule)

            // Охрана не должна завершать собственный источник защиты: цель,
            // совпавшая с VPN-приложением, снимается вместе с выбором.
            if let rule = _vpnAppRule, targets.contains(rule) {
                targets = targets.filter { $0 != rule }
            }
            emit(.vpnApp)
        }
    }

    private var _targets: [String]

    public var targets: [String] {
        get { _targets }
        set {
            _targets = newValue
            defaults.set(newValue, forKey: Key.targets)
            emit(.targets)
        }
    }

    private static func loadTargets(from defaults: UserDefaults) -> [String] {
        if let stored = defaults.stringArray(forKey: Key.targets) { return stored }

        let legacy = (defaults.stringArray(forKey: Key.legacyBundleIDs) ?? [])
            + (defaults.stringArray(forKey: Key.legacyExecutables) ?? [])
        if !legacy.isEmpty { defaults.set(legacy, forKey: Key.targets) }
        return legacy
    }

    private var _blockedCountryCodes: [String]

    public var blockedCountryCodes: [String] {
        get { _blockedCountryCodes }
        set {
            let normalized = Array(Set(newValue.map { $0.uppercased() })).sorted()
            _blockedCountryCodes = normalized
            defaults.set(normalized, forKey: Key.blockedCountryCodes)
            emit(.blacklist)
        }
    }

    private var _blockedIPRangeTexts: [String]
    public var blockedIPRangeTexts: [String] {
        get { _blockedIPRangeTexts }
        set {
            _blockedIPRangeTexts = newValue
            defaults.set(newValue, forKey: Key.blockedIPRangeTexts)
            emit(.blacklist)
        }
    }

    private var _ipinfoToken: String
    public private(set) var ipinfoToken: String {
        get { _ipinfoToken }
        set { _ipinfoToken = newValue }
    }

    /// Токен становится «сохранённым» только после успешной записи в связку ключей.
    /// Иначе приложение работало бы с токеном, которого не будет после перезапуска,
    /// а пользователь не знал бы об этом.
    @discardableResult
    public func setIPInfoToken(_ token: String) -> Result<Void, SettingsPersistenceError> {
        let value = token.isEmpty ? nil : token

        if case .failure(let error) = secrets.write(value, account: Self.tokenAccount) {
            guard case .keychain(let status) = error else { return .failure(.keychainWriteFailed(0)) }
            return .failure(.keychainWriteFailed(status))
        }

        _ipinfoToken = token
        tokenBox.value = value
        emit(.ipinfoToken)
        return .success(())
    }

    /// Разбор строки чёрного списка живёт в store, а не во View: раньше мусорная
    /// запись молча попадала в настройки и висела там с пометкой «не разобран».
    @discardableResult
    public func addBlockedEntry(_ text: String) -> Result<Void, BlacklistEntryError> {
        let entry = text.trimmingCharacters(in: .whitespaces)
        guard !entry.isEmpty else { return .failure(.empty) }

        if entry.count == 2, entry.allSatisfy(\.isLetter) {
            let code = entry.uppercased()
            guard !blockedCountryCodes.contains(code) else { return .failure(.duplicate) }
            blockedCountryCodes += [code]
            return .success(())
        }

        guard let range = IPRange(entry) else { return .failure(.invalidEntry) }
        guard !blockedIPRangeTexts.contains(range.text) else { return .failure(.duplicate) }
        blockedIPRangeTexts += [range.text]
        return .success(())
    }

    public func removeBlockedEntry(_ entry: String) {
        blockedCountryCodes = blockedCountryCodes.filter { $0 != entry }
        blockedIPRangeTexts = blockedIPRangeTexts.filter { $0 != entry }
    }

    public var blockedEntries: [String] {
        blockedCountryCodes + blockedIPRangeTexts
    }

    public func onGuardConfigurationChange(
        _ handler: @escaping (GuardConfigurationChange) -> Void
    ) {
        guardChangeHandlers.append(handler)
    }

    private func emit(_ field: GuardConfigurationChange.Field) {
        let change = GuardConfigurationChange(field: field)
        for handler in guardChangeHandlers { handler(change) }
    }

    public var guardConfig: GuardConfig {
        GuardConfig(
            vpnAppRule: vpnAppRule,
            blockedCountries: Set(blockedCountryCodes),
            blockedIPRanges: blockedIPRangeTexts.compactMap(IPRange.init),
            targets: targets
        )
    }
}
