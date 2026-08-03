import Foundation

/// Что ответил каждый гео-сервис в одной пробе — материал для попапа.
///
/// Отчёт, а не голый вердикт: пользователю, у которого молчит ipinfo, нужно видеть,
/// кто именно молчит и есть ли вообще сеть. Решение охраны выводится отсюда же
/// (`outcome`), поэтому показанное на экране и применённое к целям — одно и то же.
public struct GeoProbeReport: Equatable, Sendable {

    public enum SourceOutcome: Equatable, Sendable {
        case answered(String)
        case failed(GeoFailure)
        case notRequested
    }

    public let ip: String?
    public let ipinfo: SourceOutcome
    public let confirmation: SourceOutcome
    public let confirmSource: ConfirmSource?
    public let hasNetworkPath: Bool
    public let checkedAt: Date

    public init(
        ip: String?,
        ipinfo: SourceOutcome,
        confirmation: SourceOutcome,
        confirmSource: ConfirmSource?,
        hasNetworkPath: Bool,
        checkedAt: Date
    ) {
        self.ip = ip
        self.ipinfo = ipinfo
        self.confirmation = confirmation
        self.confirmSource = confirmSource
        self.hasNetworkPath = hasNetworkPath
        self.checkedAt = checkedAt
    }

    /// Оба источника ответили — показывать нечего, кроме самих ответов.
    public var isFullyAnswered: Bool {
        if case .answered = ipinfo, case .answered = confirmation { return true }
        return false
    }

    public var outcome: GeoOutcome {
        guard case .answered(let country) = ipinfo, let ip else {
            if case .failed(let failure) = ipinfo { return .unavailable(failure.displayText) }
            return .unavailable("нет данных")
        }
        var confirmed: String?
        if case .answered(let country) = confirmation { confirmed = country }
        return .resolved(GeoReading(
            ip: ip,
            primaryCountry: country,
            confirmedCountry: confirmed,
            confirmSource: confirmed == nil ? nil : confirmSource
        ))
    }
}
