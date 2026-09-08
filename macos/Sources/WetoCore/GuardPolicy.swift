import Foundation

public struct GuardConfig: Equatable, Sendable {

    /// Правило выбранного VPN-приложения в том же виде, что элементы `targets`:
    /// bundle ID или путь к бинарнику.
    public let vpnAppRule: String?

    public let blockedCountries: Set<String>
    public let blockedIPRanges: [IPRange]

    /// Пустой whitelist — нормальное умолчание: он не сужает ничего.
    /// Непустой требует, чтобы выход совпал хотя бы с одной записью.
    public let allowedCountries: Set<String>
    public let allowedIPRanges: [IPRange]

    public let targets: [String]

    public var hasTargets: Bool { !targets.isEmpty }

    public var hasWhitelist: Bool { !allowedCountries.isEmpty || !allowedIPRanges.isEmpty }

    public init(
        vpnAppRule: String?,
        blockedCountries: Set<String>,
        blockedIPRanges: [IPRange],
        allowedCountries: Set<String>,
        allowedIPRanges: [IPRange],
        targets: [String]
    ) {
        self.vpnAppRule = vpnAppRule
        self.blockedCountries = blockedCountries
        self.blockedIPRanges = blockedIPRanges
        self.allowedCountries = allowedCountries
        self.allowedIPRanges = allowedIPRanges
        self.targets = targets
    }
}

public struct GuardSignals: Equatable, Sendable {
    public let isEnabled: Bool
    public let vpn: VPNAppStatus
    public let geo: GeoOutcome
    public let config: GuardConfig

    public init(isEnabled: Bool, vpn: VPNAppStatus, geo: GeoOutcome, config: GuardConfig) {
        self.isEnabled = isEnabled
        self.vpn = vpn
        self.geo = geo
        self.config = config
    }
}

/// Нет доказательства ни утечки, ни защиты. Ответ на такое — пауза, а не завершение.
public enum UnprovenReason: Equatable, Sendable {
    /// ipinfo молчит, и адрес никем не назван.
    case geoUnavailable(String)
    /// Резервный сервис назвал другой адрес: страна не проверена. Терпимости не получает.
    case addressChanged(observed: String)
    /// ipinfo ответил, подтверждающие сервисы молчат. Safe без подтверждения не бывает.
    case confirmationUnavailable
}

/// Положительное доказательство опасности. Только оно завершает цели.
public enum UnsafeEvidence: Equatable, Sendable {
    case vpnAppNotRunning
    case blacklistedIP(String)
    case blockedCountry(code: String, source: String)
    case countryConflict(primary: String, confirmed: String)
    case notWhitelistedIP(String)
    case notWhitelistedCountry(String)
    /// Потолок паузы: подтверждения не дождались.
    case pauseExpired
}

public enum GuardDecision: Equatable, Sendable {
    case safe
    case unproven(UnprovenReason)
    case kill(UnsafeEvidence)
}

public enum GuardPolicy {

    /// Основания, видные без сети. `nil` — «локальных оснований нет, решает гео».
    /// Невыбранное приложение оснований не даёт: это дешёвый дополнительный сигнал,
    /// а не условие работы охраны.
    public static func decideLocal(
        isEnabled: Bool,
        vpn: VPNAppStatus,
        config: GuardConfig
    ) -> GuardDecision? {
        guard isEnabled, config.hasTargets else { return .safe }
        guard config.vpnAppRule != nil else { return nil }

        switch vpn {
        case .notChosen, .running:
            // Запущенное приложение — ещё не доказательство, что трафик в туннеле.
            return nil
        case .notRunning:
            return .kill(.vpnAppNotRunning)
        }
    }

    public static func decide(_ signals: GuardSignals) -> GuardDecision {
        if let local = decideLocal(isEnabled: signals.isEnabled, vpn: signals.vpn, config: signals.config) {
            return local
        }

        guard let reading = signals.geo.reading else {
            switch signals.geo {
            case .addressChanged(let observed, _): return .unproven(.addressChanged(observed: observed))
            case .unavailable(let detail): return .unproven(.geoUnavailable(detail))
            case .resolved, .degraded: return .unproven(.geoUnavailable("нет данных"))
            }
        }

        if signals.config.blockedIPRanges.contains(where: { $0.contains(reading.ip) }) {
            return .kill(.blacklistedIP(reading.ip))
        }

        let blocked = Set(signals.config.blockedCountries.map { $0.uppercased() })
        let primary = reading.primaryCountry.uppercased()
        if blocked.contains(primary) {
            return .kill(.blockedCountry(code: primary, source: "ipinfo"))
        }

        // Без подтверждения safe не бывает — но и утечка не доказана: пауза, не завершение.
        guard let confirmedRaw = reading.confirmedCountry else {
            return .unproven(.confirmationUnavailable)
        }
        let confirmed = confirmedRaw.uppercased()

        if blocked.contains(confirmed) {
            return .kill(.blockedCountry(code: confirmed, source: reading.confirmSource?.rawValue ?? "confirm"))
        }
        if primary != confirmed {
            return .kill(.countryConflict(primary: primary, confirmed: confirmed))
        }

        let config = signals.config
        guard config.hasWhitelist else { return .safe }
        if config.allowedIPRanges.contains(where: { $0.contains(reading.ip) }) { return .safe }
        if Set(config.allowedCountries.map { $0.uppercased() }).contains(confirmed) { return .safe }
        if !config.allowedIPRanges.isEmpty { return .kill(.notWhitelistedIP(reading.ip)) }
        return .kill(.notWhitelistedCountry(confirmed))
    }
}
