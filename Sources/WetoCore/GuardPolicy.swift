import Foundation

/// Настройки охраны, влияющие на решение.
public struct GuardConfig: Equatable, Sendable {
    /// `UserDefinedName` сервиса из SCDynamicStore, например "Happ".
    public let vpnServiceName: String?
    /// Коды стран ISO alpha-2 в верхнем регистре.
    public let blockedCountries: Set<String>
    public let blockedIPRanges: [IPRange]
    /// Цели под охраной: приложения, бинарники и команды одним списком.
    /// Разрешение записи в конкретный путь — забота слоя системы,
    /// политике достаточно знать, что цели вообще заданы.
    public let targets: [String]

    /// Охранять нечего, если не задано ни одной цели.
    public var hasTargets: Bool { !targets.isEmpty }

    public init(
        vpnServiceName: String?,
        blockedCountries: Set<String>,
        blockedIPRanges: [IPRange],
        targets: [String]
    ) {
        self.vpnServiceName = vpnServiceName
        self.blockedCountries = blockedCountries
        self.blockedIPRanges = blockedIPRanges
        self.targets = targets
    }
}

/// Полный снимок мира, на основании которого принимается решение.
public struct GuardSignals: Equatable, Sendable {
    public let isEnabled: Bool
    public let vpn: VPNStatus
    public let geo: GeoOutcome
    public let config: GuardConfig

    public init(isEnabled: Bool, vpn: VPNStatus, geo: GeoOutcome, config: GuardConfig) {
        self.isEnabled = isEnabled
        self.vpn = vpn
        self.geo = geo
        self.config = config
    }
}

/// Причина, по которой цели признаны небезопасными.
///
/// Типизирована намеренно: уходит в журнал, в текст попапа и в цвет индикатора.
/// При ложном срабатывании должно быть видно, какое звено сработало.
public enum UnsafeReason: Equatable, Sendable {
    case vpnNotConfigured
    case vpnDown
    case vpnNotPrimary
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

/// Чистая функция принятия решения. Ни одного системного вызова.
///
/// Порядок проверок не косметический: он задаёт приоритет причины и экономит
/// сетевые запросы. Шаги 1–3 решаются локально за микросекунды, шаги 4–9
/// требуют результата сетевой пробы.
public enum GuardPolicy {

    /// Решение, принимаемое без обращения к сети.
    ///
    /// Возвращает `nil`, если локальных оснований завершать цели нет и нужен
    /// сетевой вердикт. Отдельный метод существует потому, что падение VPN
    /// видно из SCDynamicStore мгновенно — самый частый сценарий отрабатывает
    /// за микросекунды, не дожидаясь HTTP-запроса.
    public static func decideLocal(
        isEnabled: Bool,
        vpn: VPNStatus,
        config: GuardConfig
    ) -> GuardDecision? {
        guard isEnabled, config.hasTargets else { return .safe }
        guard config.vpnServiceName != nil else { return .kill(.vpnNotConfigured) }

        switch vpn {
        case .notConfigured:
            return .kill(.vpnNotConfigured)
        case .down:
            return .kill(.vpnDown)
        case .up(let isPrimary):
            return isPrimary ? nil : .kill(.vpnNotPrimary)
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

        // Шаги 4–9: требуют результата сетевой пробы.
        guard case .resolved(let reading) = signals.geo else {
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
