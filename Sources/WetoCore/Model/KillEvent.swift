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
    public let killedPIDs: [Int32]

    public init(
        id: UUID = UUID(),
        date: Date,
        targetNames: [String],
        kind: KillEventKind,
        reasonText: String,
        ip: String?,
        country: String?,
        killedPIDs: [Int32]
    ) {
        self.id = id
        self.date = date
        self.targetNames = targetNames
        self.kind = kind
        self.reasonText = reasonText
        self.ip = ip
        self.country = country
        self.killedPIDs = killedPIDs
    }

    public var targetsText: String {
        targetNames.isEmpty ? "неизвестная цель" : targetNames.joined(separator: ", ")
    }

    public var summaryText: String {
        "\(kind.displayText) — \(reasonText)"
    }
}

extension UnsafeReason {

    public var displayText: String {
        switch self {
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
        if case .confirmationUnavailable = self { return true }
        return false
    }
}
