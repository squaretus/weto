import Foundation

public enum KillEventKind: String, Codable, Equatable, Sendable {

    case terminated

    case launchBlocked

    public var displayText: String {
        switch self {
        case .terminated: return "завершено"
        case .launchBlocked: return "запуск запрещён"
        }
    }
}

public struct KillEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date

    public let targetNames: [String]
    public let kind: KillEventKind
    public let reasonText: String
    public let ip: String?
    public let country: String?
    public let confirmedCountry: String?
    public let confirmSource: String?
    public let killedPIDs: [Int32]

    public init(
        id: UUID = UUID(),
        date: Date,
        targetNames: [String],
        kind: KillEventKind,
        reasonText: String,
        ip: String?,
        country: String?,
        confirmedCountry: String? = nil,
        confirmSource: String? = nil,
        killedPIDs: [Int32]
    ) {
        self.id = id
        self.date = date
        self.targetNames = targetNames
        self.kind = kind
        self.reasonText = reasonText
        self.ip = ip
        self.country = country
        self.confirmedCountry = confirmedCountry
        self.confirmSource = confirmSource
        self.killedPIDs = killedPIDs
    }

    public var targetsText: String {
        targetNames.isEmpty ? "неизвестная цель" : targetNames.joined(separator: ", ")
    }

    public var summaryText: String {
        "\(kind.displayText) — \(Self.lowercasingFirstWord(reasonText))"
    }

    private static func lowercasingFirstWord(_ text: String) -> String {
        let scalars = Array(text)
        guard scalars.count >= 2 else { return text.lowercased() }
        if scalars[0].isUppercase && scalars[1].isUppercase { return text }
        return scalars[0].lowercased() + String(scalars.dropFirst())
    }
}

extension UnsafeReason {

    public var displayText: String {
        switch self {
        case .verificationPending:
            return "Подключение ещё не проверено"
        case .vpnNotConfigured:
            return "VPN-сервис не выбран в настройках"
        case .vpnDown:
            return "VPN не поднят"
        case .vpnNotPrimary:
            return "VPN поднят, но трафик идёт мимо него"
        case .geoUnavailable(let detail):
            return "Не удалось определить внешний адрес: \(detail)"
        case .blacklistedIP(let ip):
            return "Адрес \(ip) в чёрном списке"
        case .blockedCountry(let code, let source):
            return "Обнаружена страна \(code) по данным \(source)"
        case .confirmationUnavailable:
            return "Подтверждающие сервисы недоступны"
        case .countryConflict(let primary, let confirmed):
            return "Расхождение стран: ipinfo — \(primary), подтверждение — \(confirmed)"
        }
    }

    public var isDegradedRatherThanBlocked: Bool {
        switch self {
        case .confirmationUnavailable, .geoUnavailable: return true
        default: return false
        }
    }

    public var statusTitle: String {
        switch self {
        case .verificationPending:
            return "Проверка подключения"
        case .geoUnavailable:
            return "Ipinfo недоступен"
        case .confirmationUnavailable:
            return "Ipwhois недоступен"
        default:
            return "Цели завершены"
        }
    }
}
