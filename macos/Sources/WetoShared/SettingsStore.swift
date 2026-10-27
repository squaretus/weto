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

/// Вид списка геоправил. Разбор записи, проверка дубликата и удаление —
/// один путь на оба списка: два экземпляра одного алгоритма разъезжались бы
/// молча, а расходиться им нельзя.
public enum GeoListKind: Equatable, Sendable {
    case blocked
    case allowed
}

public enum GeoListEntryError: Error, Equatable, Sendable {
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
    /// Токен терминальной версии лежит файлом: фоновому сервису диалог связки
    /// ключей показать некому.
    case fileWriteFailed(String)

    public var displayText: String {
        switch self {
        case .keychainWriteFailed(let status):
            return "не удалось сохранить токен в связку ключей (ошибка \(status))"
        case .fileWriteFailed(let detail):
            return "не удалось сохранить токен в файл: \(detail)"
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
        /// Туннель терминальной версии. Окно настроек его не задаёт.
        case vpnTunnel
        case ipinfoToken
        case blacklist
        case whitelist
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
        static let pauseCeilingSeconds = "pauseCeilingSeconds"
        /// Ключ новый: смысл выбора изменился с «идентификатор туннеля» на «правило
        /// приложения», и переносить прежнее значение нельзя — оно называет `utunN`
        /// или UUID сервиса, а не приложение.
        static let vpnAppRule = "vpnAppRule"
        /// Имя интерфейса VPN-туннеля. Только у терминальной версии: её настройки
        /// живут в своём наборе (`com.weto.cli`), и окно приложения ключа не видит.
        static let vpnTunnel = "vpnTunnel"
        static let targets = "targets"

        static let legacyBundleIDs = "targetBundleIDs"
        static let legacyExecutables = "targetExecutables"
        static let blockedCountryCodes = "blockedCountryCodes"
        static let blockedIPRangeTexts = "blockedIPRangeTexts"
        static let allowedCountryCodes = "allowedCountryCodes"
        static let allowedIPRangeTexts = "allowedIPRangeTexts"
    }

    private static let tokenAccount = "token"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secrets: SecretStoring

    @ObservationIgnored public let tokenBox = TokenBox()

    @ObservationIgnored
    private var guardChangeHandlers: [(GuardConfigurationChange) -> Void] = []

    @ObservationIgnored
    private var pauseCeilingHandlers: [(PauseCeiling) -> Void] = []

    /// Идёт перечитывание набора: значения пришли из него же, и писать их обратно
    /// нельзя — запись прочитанного затёрла бы правку, которую вторая копия успела
    /// сделать между чтением и записью.
    @ObservationIgnored
    private var isReloading = false

    private func persist(_ value: Any?, forKey key: String) {
        guard !isReloading else { return }
        defaults.set(value, forKey: key)
    }

    public init(defaults: UserDefaults, secrets: SecretStoring) {
        self.defaults = defaults
        self.secrets = secrets

        self._isEnabled = defaults.object(forKey: Key.isEnabled) as? Bool ?? true
        self._appTheme = defaults.string(forKey: Key.appTheme)
            .flatMap(AppTheme.init(rawValue:)) ?? .dark
        self._pauseCeiling = PauseCeiling(storedSeconds: defaults.object(forKey: Key.pauseCeilingSeconds) as? Int)
        self._vpnAppRule = defaults.string(forKey: Key.vpnAppRule)
        self._vpnTunnel = defaults.string(forKey: Key.vpnTunnel)
        self._targets = Self.loadTargets(from: defaults)
        self._blockedCountryCodes = defaults.stringArray(forKey: Key.blockedCountryCodes) ?? []
        self._blockedIPRangeTexts = defaults.stringArray(forKey: Key.blockedIPRangeTexts) ?? []
        // Отсутствие ключей означает пустой whitelist — так ранее сохранённые
        // установки открываются с прежним поведением.
        self._allowedCountryCodes = defaults.stringArray(forKey: Key.allowedCountryCodes) ?? []
        self._allowedIPRangeTexts = defaults.stringArray(forKey: Key.allowedIPRangeTexts) ?? []
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
            persist(newValue, forKey: Key.isEnabled)
            emit(.guardEnabled)
        }
    }

    private var _appTheme: AppTheme
    public var appTheme: AppTheme {
        get { _appTheme }
        set { _appTheme = newValue; defaults.set(newValue.rawValue, forKey: Key.appTheme) }
    }

    /// Не `GuardConfigurationChange`: решение политики потолок не меняет,
    /// и «правка настроек» попросила бы пробу и запись в журнале проверок.
    /// Подписчик ровно один — контроллер охраны, он и выставляет потолок машине.
    private var _pauseCeiling: PauseCeiling
    public var pauseCeiling: PauseCeiling {
        get { _pauseCeiling }
        set {
            _pauseCeiling = newValue
            persist(newValue.rawValue, forKey: Key.pauseCeilingSeconds)
            for handler in pauseCeilingHandlers { handler(newValue) }
        }
    }

    public func onPauseCeilingChange(_ handler: @escaping (PauseCeiling) -> Void) {
        pauseCeilingHandlers.append(handler)
    }

    private var _vpnAppRule: String?

    /// Выбранное VPN-приложение — тем же правилом, что цели: bundle ID или путь.
    public var vpnAppRule: String? {
        get { _vpnAppRule }
        set {
            let cleaned = newValue?.trimmingCharacters(in: .whitespaces)
            _vpnAppRule = (cleaned?.isEmpty ?? true) ? nil : cleaned
            persist(_vpnAppRule, forKey: Key.vpnAppRule)

            // Охрана не должна завершать собственный источник защиты: цель,
            // совпавшая с VPN-приложением, снимается вместе с выбором.
            if let rule = _vpnAppRule, targets.contains(rule) {
                targets = targets.filter { $0 != rule }
            }
            // VPN задаётся одним способом: выбор приложения снимает туннель.
            if _vpnAppRule != nil, _vpnTunnel != nil {
                vpnTunnel = nil
            }
            emit(.vpnApp)
        }
    }

    private var _vpnTunnel: String?

    /// Выбранный VPN-туннель — имя интерфейса. Задаёт его только терминальная версия;
    /// выбор туннеля снимает приложение, и наоборот.
    public var vpnTunnel: String? {
        get { _vpnTunnel }
        set {
            let cleaned = newValue?.trimmingCharacters(in: .whitespaces)
            _vpnTunnel = (cleaned?.isEmpty ?? true) ? nil : cleaned
            persist(_vpnTunnel, forKey: Key.vpnTunnel)

            if _vpnTunnel != nil, _vpnAppRule != nil {
                vpnAppRule = nil
            }
            emit(.vpnTunnel)
        }
    }

    private var _targets: [String]

    public var targets: [String] {
        get { _targets }
        set {
            _targets = newValue
            persist(newValue, forKey: Key.targets)
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
            persist(normalized, forKey: Key.blockedCountryCodes)
            emit(.blacklist)
        }
    }

    private var _blockedIPRangeTexts: [String]
    public var blockedIPRangeTexts: [String] {
        get { _blockedIPRangeTexts }
        set {
            _blockedIPRangeTexts = newValue
            persist(newValue, forKey: Key.blockedIPRangeTexts)
            emit(.blacklist)
        }
    }

    private var _allowedCountryCodes: [String]
    public var allowedCountryCodes: [String] {
        get { _allowedCountryCodes }
        set {
            let normalized = Array(Set(newValue.map { $0.uppercased() })).sorted()
            _allowedCountryCodes = normalized
            persist(normalized, forKey: Key.allowedCountryCodes)
            emit(.whitelist)
        }
    }

    private var _allowedIPRangeTexts: [String]
    public var allowedIPRangeTexts: [String] {
        get { _allowedIPRangeTexts }
        set {
            _allowedIPRangeTexts = newValue
            persist(newValue, forKey: Key.allowedIPRangeTexts)
            emit(.whitelist)
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
            switch error {
            case .keychain(let status): return .failure(.keychainWriteFailed(status))
            case .file(let detail): return .failure(.fileWriteFailed(detail))
            }
        }

        _ipinfoToken = token
        tokenBox.value = value
        emit(.ipinfoToken)
        return .success(())
    }

    /// Разбор строки живёт в store, а не во View: раньше мусорная запись молча
    /// попадала в настройки и висела там с пометкой «не разобран».
    ///
    /// Путь один на оба списка — различает их только `kind`.
    @discardableResult
    public func addEntry(_ text: String, to kind: GeoListKind) -> Result<Void, GeoListEntryError> {
        let entry = text.trimmingCharacters(in: .whitespaces)
        guard !entry.isEmpty else { return .failure(.empty) }

        if entry.count == 2, entry.allSatisfy(\.isLetter) {
            let code = entry.uppercased()
            guard !countryCodes(of: kind).contains(code) else { return .failure(.duplicate) }
            setCountryCodes(countryCodes(of: kind) + [code], of: kind)
            return .success(())
        }

        guard let range = IPRange(entry) else { return .failure(.invalidEntry) }
        guard !rangeTexts(of: kind).contains(range.text) else { return .failure(.duplicate) }
        setRangeTexts(rangeTexts(of: kind) + [range.text], of: kind)
        return .success(())
    }

    public func removeEntry(_ entry: String, from kind: GeoListKind) {
        setCountryCodes(countryCodes(of: kind).filter { $0 != entry }, of: kind)
        setRangeTexts(rangeTexts(of: kind).filter { $0 != entry }, of: kind)
    }

    public func entries(of kind: GeoListKind) -> [String] {
        countryCodes(of: kind) + rangeTexts(of: kind)
    }

    private func countryCodes(of kind: GeoListKind) -> [String] {
        switch kind {
        case .blocked: return blockedCountryCodes
        case .allowed: return allowedCountryCodes
        }
    }

    private func setCountryCodes(_ codes: [String], of kind: GeoListKind) {
        switch kind {
        case .blocked: blockedCountryCodes = codes
        case .allowed: allowedCountryCodes = codes
        }
    }

    private func rangeTexts(of kind: GeoListKind) -> [String] {
        switch kind {
        case .blocked: return blockedIPRangeTexts
        case .allowed: return allowedIPRangeTexts
        }
    }

    private func setRangeTexts(_ texts: [String], of kind: GeoListKind) {
        switch kind {
        case .blocked: blockedIPRangeTexts = texts
        case .allowed: allowedIPRangeTexts = texts
        }
    }

    // Обёртки для привязок UI: ничего, кроме делегирования в общий путь.

    @discardableResult
    public func addBlockedEntry(_ text: String) -> Result<Void, GeoListEntryError> {
        addEntry(text, to: .blocked)
    }

    public func removeBlockedEntry(_ entry: String) { removeEntry(entry, from: .blocked) }

    public var blockedEntries: [String] { entries(of: .blocked) }

    @discardableResult
    public func addAllowedEntry(_ text: String) -> Result<Void, GeoListEntryError> {
        addEntry(text, to: .allowed)
    }

    public func removeAllowedEntry(_ entry: String) { removeEntry(entry, from: .allowed) }

    public var allowedEntries: [String] { entries(of: .allowed) }

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
            allowedCountries: Set(allowedCountryCodes),
            allowedIPRanges: allowedIPRangeTexts.compactMap(IPRange.init),
            targets: targets,
            vpnTunnel: vpnTunnel
        )
    }

    // MARK: - Перечитывание набора

    /// Перечитывает набор настроек и применяет отличающиеся поля через обычные
    /// сеттеры — чтобы сработали те же подписки, что у правки из окна.
    ///
    /// Нужно терминальной версии: настройки правит одна копия (`weto target add`),
    /// а охраняет другая (`weto run`). Совпадающие поля не трогаются вовсе:
    /// иначе каждое перечитывание поднимало бы ревизию и просило пробу раз в секунду.
    /// Возвращает поля, которые сменились, — для лога.
    @discardableResult
    public func reloadFromDefaults() -> [GuardConfigurationChange.Field] {
        var changed: [GuardConfigurationChange.Field] = []
        let collect: (GuardConfigurationChange) -> Void = { changed.append($0.field) }
        guardChangeHandlers.append(collect)
        let collector = guardChangeHandlers.count - 1
        isReloading = true
        defer {
            isReloading = false
            guardChangeHandlers.remove(at: collector)
        }

        let stored = Self.loadTargets(from: defaults)
        if stored != _targets { targets = stored }

        let blocked = defaults.stringArray(forKey: Key.blockedCountryCodes) ?? []
        if blocked != _blockedCountryCodes { blockedCountryCodes = blocked }
        let blockedRanges = defaults.stringArray(forKey: Key.blockedIPRangeTexts) ?? []
        if blockedRanges != _blockedIPRangeTexts { blockedIPRangeTexts = blockedRanges }
        let allowed = defaults.stringArray(forKey: Key.allowedCountryCodes) ?? []
        if allowed != _allowedCountryCodes { allowedCountryCodes = allowed }
        let allowedRanges = defaults.stringArray(forKey: Key.allowedIPRangeTexts) ?? []
        if allowedRanges != _allowedIPRangeTexts { allowedIPRangeTexts = allowedRanges }

        // Сперва снимается выбор, потом ставится новый: сеттер выбора снимает
        // другую сторону сам, и обратный порядок стёр бы только что прочитанное.
        let app = defaults.string(forKey: Key.vpnAppRule)
        let tunnel = defaults.string(forKey: Key.vpnTunnel)
        if app == nil, _vpnAppRule != nil { vpnAppRule = nil }
        if tunnel == nil, _vpnTunnel != nil { vpnTunnel = nil }
        if let app, app != _vpnAppRule { vpnAppRule = app }
        if let tunnel, tunnel != _vpnTunnel { vpnTunnel = tunnel }

        let enabled = defaults.object(forKey: Key.isEnabled) as? Bool ?? true
        if enabled != _isEnabled { isEnabled = enabled }

        let ceiling = PauseCeiling(storedSeconds: defaults.object(forKey: Key.pauseCeilingSeconds) as? Int)
        if ceiling != _pauseCeiling { pauseCeiling = ceiling }

        // Токен лежит не в наборе, а в хранилище секретов, но правится тем же
        // путём — второй копией, — и подхватываться обязан так же.
        let token = secrets.read(account: Self.tokenAccount) ?? ""
        if token != _ipinfoToken {
            _ipinfoToken = token
            tokenBox.value = token.isEmpty ? nil : token
            emit(.ipinfoToken)
        }

        return changed
    }
}
