import Foundation

public struct GuardConfig: Equatable, Sendable {

    /// Правило выбранного VPN-приложения в том же виде, что элементы `targets`:
    /// bundle ID или путь к бинарнику.
    public let vpnAppRule: String?

    /// Выбранный VPN-туннель — имя интерфейса (`wg0`, `tun0`, `utun6`). Задаётся
    /// только в терминальной версии и взаимоисключающе с приложением: на сервере
    /// VPN поднимает `wg-quick` или юнит без приложения, и имена там стабильны.
    public let vpnTunnel: String?

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
        targets: [String],
        vpnTunnel: String? = nil
    ) {
        self.vpnAppRule = vpnAppRule
        self.vpnTunnel = vpnTunnel
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
    public let tunnel: VPNTunnelStatus
    public let geo: GeoOutcome
    public let config: GuardConfig

    public init(
        isEnabled: Bool,
        vpn: VPNAppStatus,
        tunnel: VPNTunnelStatus = .notChosen,
        geo: GeoOutcome,
        config: GuardConfig
    ) {
        self.isEnabled = isEnabled
        self.vpn = vpn
        self.tunnel = tunnel
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
    /// Прежний вердикт перестал описывать выход — сменилась сеть или его не было вовсе,
    /// — а ответа пробы ещё нет. Решением политики не бывает: причину ставит потеря
    /// вердикта, и до ответа пробы цели стоят.
    case exitNotVerified(VerdictStaleness.Cause)
}

/// Положительное доказательство опасности. Только оно завершает цели.
public enum UnsafeEvidence: Equatable, Sendable {
    case vpnAppNotRunning
    /// Выбранного туннеля нет среди поднятых интерфейсов. Несёт имя туннеля:
    /// запись обязана назвать тот, что был выбран в момент завершения.
    case vpnTunnelDown(String)
    /// Туннель поднят, а ядро выпускает вердиктный запрос через другой интерфейс.
    case trafficBypassesTunnel(tunnel: String, via: String)
    case blacklistedIP(String)
    case blockedCountry(code: String, source: String)
    case countryConflict(primary: String, confirmed: String)
    case notWhitelistedIP(String)
    case notWhitelistedCountry(String)
    /// Потолок паузы: подтверждения не дождались. Несёт потолок, по которому
    /// завершили: настройку могут сменить потом, а запись обязана назвать
    /// то число, что действовало.
    case pauseExpired(ceiling: TimeInterval)
}

extension UnsafeEvidence {
    public var isPauseExpired: Bool {
        if case .pauseExpired = self { return true }
        return false
    }

    /// Улика видна без сети — по процессам и интерфейсам машины. Про выход такая улика
    /// не говорит ничего, поэтому прежние адрес и страна при ней не показываются,
    /// а снимает её переоценка, когда локальная проверка улики больше не даёт.
    public var isLocal: Bool {
        switch self {
        case .vpnAppNotRunning, .vpnTunnelDown, .trafficBypassesTunnel: return true
        case .blacklistedIP, .blockedCountry, .countryConflict, .notWhitelistedIP,
             .notWhitelistedCountry, .pauseExpired:
            return false
        }
    }
}

public enum GuardDecision: Equatable, Sendable {
    case safe
    case unproven(UnprovenReason)
    case kill(UnsafeEvidence)
}

public enum GuardPolicy {

    /// Основания, видные без сети. `nil` — «локальных оснований нет, решает гео».
    /// Невыбранные приложение и туннель оснований не дают: это дешёвые дополнительные
    /// сигналы, а не условие работы охраны. Порядок: приложение, затем туннель —
    /// каждый спрашивается только тогда, когда выбран.
    public static func decideLocal(
        isEnabled: Bool,
        vpn: VPNAppStatus,
        tunnel: VPNTunnelStatus = .notChosen,
        config: GuardConfig
    ) -> GuardDecision? {
        guard isEnabled, config.hasTargets else { return .safe }

        if config.vpnAppRule != nil {
            switch vpn {
            case .notChosen, .running:
                // Запущенное приложение — ещё не доказательство, что трафик в туннеле.
                break
            case .notRunning:
                return .kill(.vpnAppNotRunning)
            }
        }

        if let chosen = config.vpnTunnel {
            switch tunnel {
            case .notChosen, .carrying:
                // Туннель несёт трафик — это ещё не доказательство безопасного выхода.
                break
            case .down:
                return .kill(.vpnTunnelDown(chosen))
            case .bypassed(let via):
                return .kill(.trafficBypassesTunnel(tunnel: chosen, via: via))
            }
        }

        return nil
    }

    public static func decide(_ signals: GuardSignals) -> GuardDecision {
        if let local = decideLocal(
            isEnabled: signals.isEnabled, vpn: signals.vpn, tunnel: signals.tunnel, config: signals.config
        ) {
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
