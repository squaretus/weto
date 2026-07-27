import Foundation
import WetoCore

/// Тон плашки в попапе. Совпадает по смыслу с `GuardStatusColor`,
/// но живёт отдельно, чтобы `WetoShared` не зависел от дизайн-модуля.
public enum BannerTone: Equatable, Sendable {
    case info, success, warn, error
}

/// Тексты состояния для попапа менюбара.
///
/// Вынесено из вьюх: это то, что пользователь читает в момент инцидента,
/// и оно должно быть под тестом.
public enum StatusPresentation {

    public static func headline(for state: GuardState) -> String {
        switch state {
        case .disabled: return "Охрана выключена"
        case .safe: return "Всё в порядке"
        case .unsafe(let reason): return reason.displayText
        }
    }

    /// Строка с деталями показания. `nil`, когда показания ещё нет —
    /// например, при падении VPN сетевая проба не выполняется вовсе.
    public static func detail(for state: GuardState, reading: GeoReading?) -> String? {
        guard let reading else { return nil }

        // ASN намеренно не показываем: в попапе он занимал место,
        // ничего не добавляя к решению — страну и адрес видно и без него.
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
