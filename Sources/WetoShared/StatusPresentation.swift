import Foundation
import WetoCore

public enum BannerTone: Equatable, Sendable {
    case info, success, warn, error
}

public enum StatusPresentation {

    public static func headline(for state: GuardState) -> String {
        switch state {
        case .disabled: return "Охрана выключена"
        case .safe: return "Всё в порядке"
        case .unsafe(let reason): return reason.displayText
        }
    }

    public static func detail(for state: GuardState, reading: GeoReading?) -> String? {
        guard let reading else { return nil }

        var parts = [reading.ip]
        parts.append("ipinfo: \(reading.primaryCountry)")

        if let confirmed = reading.confirmedCountry, let source = reading.confirmSource {
            parts.append("\(source.rawValue): \(confirmed)")
        } else {
            parts.append("подтверждение: нет")
        }

        return parts.joined(separator: " · ")
    }

    public static func bannerTone(for state: GuardState) -> BannerTone {
        switch state.statusColor {
        case .grey: return .info
        case .green: return .success
        case .yellow: return .warn
        case .red: return .error
        }
    }
}
