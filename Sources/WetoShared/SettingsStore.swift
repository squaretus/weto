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

/// Изменение настройки, от которой зависит решение охраны. Публикуется синхронно
/// на главном акторе: цель, добавленная при небезопасном состоянии, обязана быть
/// завершена сразу, а не через тик поллинга.
public struct GuardConfigurationChange: Equatable, Sendable {
    public enum Field: Equatable, Sendable {
        case guardEnabled
        case targets
        case vpnService
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
        static let vpnServiceID = "vpnServiceID"
        static let targets = "targets"

        static let legacyVPNServiceName = "vpnServiceName"
        static let legacyBundleIDs = "targetBundleIDs"
        static let legacyExecutables = "targetExecutables"
        static let blockedCountryCodes = "blockedCountryCodes"
        static let blockedIPRangeTexts = "blockedIPRangeTexts"
        static let pollIntervalSeconds = "pollIntervalSeconds"
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
        self._vpnServiceID = defaults.string(forKey: Key.vpnServiceID)
        self._targets = Self.loadTargets(from: defaults)
        self._blockedCountryCodes = defaults.stringArray(forKey: Key.blockedCountryCodes) ?? []
        self._blockedIPRangeTexts = defaults.stringArray(forKey: Key.blockedIPRangeTexts) ?? []
        let interval = defaults.double(forKey: Key.pollIntervalSeconds)
        self._pollIntervalSeconds = interval > 0 ? interval : Constants.defaultPollIntervalSeconds
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

    private var _vpnServiceID: String?
    public var vpnServiceID: String? {
        get { _vpnServiceID }
        set {
            _vpnServiceID = newValue
            defaults.set(newValue, forKey: Key.vpnServiceID)
            emit(.vpnService)
        }
    }

    /// Переносит выбор, сделанный прежней версией по имени сервиса, на устойчивый UUID.
    /// Неоднозначное имя (два сервиса зовутся одинаково) и имя сервиса, не прошедшего
    /// квалификацию VPN, не угадываем — выбор очищается, и охрана остаётся fail-closed
    /// до явного выбора пользователем.
    public func migrateLegacyVPNSelection(in snapshot: NetworkSnapshot) {
        guard let legacyName = defaults.string(forKey: Key.legacyVPNServiceName) else { return }
        defer { defaults.removeObject(forKey: Key.legacyVPNServiceName) }

        guard vpnServiceID == nil else { return }

        let matches = snapshot.vpnCandidates.filter { $0.name == legacyName }
        guard matches.count == 1 else { return }
        vpnServiceID = matches[0].uuid
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
            emit(.ipinfoToken)
        }
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
            vpnServiceID: vpnServiceID,
            blockedCountries: Set(blockedCountryCodes),
            blockedIPRanges: blockedIPRangeTexts.compactMap(IPRange.init),
            targets: targets
        )
    }
}
