import Foundation

public struct GuardConfig: Equatable, Sendable {

    /// Правило выбранного VPN-приложения в том же виде, что элементы `targets`:
    /// bundle ID или путь к бинарнику.
    public let vpnAppRule: String?

    public let blockedCountries: Set<String>
    public let blockedIPRanges: [IPRange]

    public let targets: [String]

    public var hasTargets: Bool { !targets.isEmpty }

    public init(
        vpnAppRule: String?,
        blockedCountries: Set<String>,
        blockedIPRanges: [IPRange],
        targets: [String]
    ) {
        self.vpnAppRule = vpnAppRule
        self.blockedCountries = blockedCountries
        self.blockedIPRanges = blockedIPRanges
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

public enum UnsafeReason: Equatable, Sendable {
    case verificationPending
    case vpnAppNotChosen
    case vpnAppNotRunning
    case geoUnavailable(String)
    case blacklistedIP(String)
    case blockedCountry(code: String, source: String)
    case confirmationUnavailable
    case countryConflict(primary: String, confirmed: String)
}

public enum GuardDecision: Equatable, Sendable {
    case safe
    case kill(UnsafeReason)
}

public enum GuardPolicy {

    /// Решение на время, пока локальные основания исчерпаны, а свежего гео-вердикта ещё нет.
    /// Это окно обязано быть fail-closed: иначе цели живут все секунды, что идёт запрос
    /// к ipinfo и подтверждающим сервисам.
    public static func pendingVerification(
        isEnabled: Bool,
        config: GuardConfig
    ) -> GuardDecision {
        guard isEnabled, config.hasTargets else { return .safe }
        return .kill(.verificationPending)
    }

    public static func decideLocal(
        isEnabled: Bool,
        vpn: VPNAppStatus,
        config: GuardConfig
    ) -> GuardDecision? {
        guard isEnabled, config.hasTargets else { return .safe }

        // Пустой выбор в настройках убивает сам по себе, не спрашивая статус.
        // Статус считает вызывающий, и разойтись с настройками он не должен —
        // но если разойдётся, ошибка обязана быть в сторону fail-closed.
        guard config.vpnAppRule != nil else { return .kill(.vpnAppNotChosen) }

        switch vpn {
        case .notChosen:
            return .kill(.vpnAppNotChosen)
        case .notRunning:
            return .kill(.vpnAppNotRunning)
        case .running:
            // Запущенное приложение — ещё не доказательство, что трафик идёт
            // через VPN: клиент умеет висеть в менюбаре с выключенным подключением.
            // Отвечает на это гео, и ответ обязателен.
            return nil
        }
    }

    public static func decide(_ signals: GuardSignals) -> GuardDecision {
        if let local = decideLocal(
            isEnabled: signals.isEnabled,
            vpn: signals.vpn,
            config: signals.config
        ) {
            return local
        }

        guard let reading = signals.geo.reading else {
            if case .unavailable(let detail) = signals.geo {
                return .kill(.geoUnavailable(detail))
            }
            return .kill(.geoUnavailable("нет данных"))
        }

        if signals.config.blockedIPRanges.contains(where: { $0.contains(reading.ip) }) {
            return .kill(.blacklistedIP(reading.ip))
        }

        let blocked = Set(signals.config.blockedCountries.map { $0.uppercased() })
        let primary = reading.primaryCountry.uppercased()

        if blocked.contains(primary) {
            return .kill(.blockedCountry(code: primary, source: "ipinfo"))
        }

        guard let confirmedRaw = reading.confirmedCountry else {
            return .kill(.confirmationUnavailable)
        }
        let confirmed = confirmedRaw.uppercased()

        if blocked.contains(confirmed) {
            let source = reading.confirmSource?.rawValue ?? "confirm"
            return .kill(.blockedCountry(code: confirmed, source: source))
        }

        if primary != confirmed {
            return .kill(.countryConflict(primary: primary, confirmed: confirmed))
        }

        return .safe
    }
}
