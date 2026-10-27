import Foundation

/// Состояние VPN-приложения — того, что выбрал пользователь.
///
/// Выбирается приложение, а не туннель, потому что вопрос «какой из `utunN` твой»
/// пользователю задать нельзя: имена ничего не значат, меняются при каждом
/// переподключении и у сборок мимо App Store не имеют за собой сетевого сервиса.
/// Вопрос «какое приложение поднимает тебе VPN» — отвечаемый.
public enum VPNAppStatus: Equatable, Sendable {

    case notChosen

    case notRunning

    case running
}

/// Состояние выбранного VPN-туннеля — интерфейса, названного пользователем.
///
/// Туннель выбирается только в терминальной версии: на сервере VPN поднимает
/// `wg-quick` или юнит без приложения, а имена интерфейсов стабильны. Состояние
/// считается чистой функцией из имени и снимка сети этого прохода
/// (`VPNTunnelStatus.init(chosen:snapshot:)`).
public enum VPNTunnelStatus: Equatable, Sendable {

    case notChosen

    /// Интерфейса нет среди поднятых (`IFF_UP` и `IFF_RUNNING`).
    case down

    /// Интерфейс поднят, а ядро выпускает вердиктный запрос через другой.
    case bypassed(via: String)

    /// Трафик идёт через туннель — или наружу не идёт вовсе: тогда отвечает гео.
    case carrying

    public init(chosen: String?, snapshot: NetworkSnapshot) {
        guard let chosen else {
            self = .notChosen
            return
        }
        guard snapshot.upInterfaces.contains(chosen) else {
            self = .down
            return
        }
        if let outgoing = snapshot.outgoing, outgoing.interface != chosen {
            self = .bypassed(via: outgoing.interface)
            return
        }
        self = .carrying
    }
}

public enum ConfirmSource: String, Equatable, Codable, Sendable {
    case freeipapi
    case geojs
}

public struct GeoReading: Equatable, Sendable {
    public let ip: String
    public let primaryCountry: String
    public let confirmedCountry: String?
    public let confirmSource: ConfirmSource?

    public init(
        ip: String,
        primaryCountry: String,
        confirmedCountry: String?,
        confirmSource: ConfirmSource?
    ) {
        self.ip = ip
        self.primaryCountry = primaryCountry
        self.confirmedCountry = confirmedCountry
        self.confirmSource = confirmSource
    }
}

public enum GeoOutcome: Equatable, Sendable {
    case resolved(GeoReading)

    /// ipinfo молчит, но резервный сервис назвал наш адрес, и он совпал с адресом
    /// прошлого вердикта. Тот же адрес — та же страна, поэтому круг гео не нужен:
    /// в дело идёт прошлое чтение, и проверки по нему прогоняются полностью.
    /// Снисхождение выдаётся за доказательство неизменности адреса, а не за давность.
    case degraded(previous: GeoReading, detail: String)

    case unavailable(String)

    /// Резервный сервис назвал адрес, и он не совпал с адресом прошлого вердикта:
    /// страна не проверена, прошлое чтение к новому адресу не относится.
    case addressChanged(observed: String, previous: GeoReading)

    /// Проба дала годный ответ: адрес и страна названы источником, а не взяты
    /// из прошлого вердикта.
    public var isResolved: Bool {
        if case .resolved = self { return true }
        return false
    }

    /// Почему годного ответа нет — текстом источника, без нашей трактовки.
    public var unavailableDetail: String? {
        switch self {
        case .resolved: return nil
        case .degraded(_, let detail): return detail
        case .unavailable(let detail): return detail
        case .addressChanged(let observed, let previous):
            return "адрес сменился: был \(previous.ip), стал \(observed)"
        }
    }

    /// Чтение, по которому принимается решение. `nil` — вердикта нет вовсе.
    public var reading: GeoReading? {
        switch self {
        case .resolved(let reading): return reading
        case .degraded(let previous, _): return previous
        case .unavailable: return nil
        case .addressChanged: return nil
        }
    }
}
