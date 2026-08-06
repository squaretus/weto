import Foundation
import WetoCore

public struct StatusLine: Equatable, Sendable, Identifiable {
    public let key: String
    public let value: String

    public var id: String { key }

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// Что написать, когда целей на машине не запущено. Совет про VPN — часть
/// смысла, а не оформления, поэтому решение живёт здесь и проверяется тестом.
public struct IdleTargetsNotice: Equatable, Sendable {
    public let text: String

    /// Появляется только тогда, когда это правда: после срабатывания охраны
    /// цели молчат не потому, что всё хорошо, а потому что VPN уже упал.
    public let hint: String?

    public init(text: String, hint: String?) {
        self.text = text
        self.hint = hint
    }
}

public enum StatusPresentation {

    public static func idleTargets(for state: GuardState) -> IdleTargetsNotice {
        switch state {
        case .safe:
            return IdleTargetsNotice(text: "Цели не запущены", hint: "— VPN можно выключать")
        case .unsafe, .disabled:
            return IdleTargetsNotice(text: "Цели не запущены", hint: nil)
        }
    }

    public static let unknownIP = "неизвестен"
    public static let missingValue = "—"
    public static let confirmationLabel = "подтверждение"

    public static func title(for state: GuardState) -> String {
        switch state {
        case .disabled: return "Охрана выключена"
        case .safe: return "На страже"
        case .unsafe(let reason): return reason.statusTitle
        }
    }

    public static func lines(for state: GuardState, reading: GeoReading?) -> [StatusLine] {
        let known = knownReading(for: state, reading: reading)

        // Подпись строки — имя сервиса, который реально ответил: подтверждающих
        // два, и показывать чужое имя было бы ложью.
        return [
            StatusLine(key: "IP", value: known?.ip ?? unknownIP),
            StatusLine(key: "ipinfo", value: known?.primaryCountry ?? missingValue),
            StatusLine(
                key: known?.confirmSource?.rawValue ?? confirmationLabel,
                value: known?.confirmedCountry ?? missingValue
            ),
        ]
    }

    /// Строки по отчёту последней пробы: показываем, кто именно ответил, кто молчит
    /// и была ли вообще сеть. Без этого отказ ipinfo выглядел на экране как пустые прочерки.
    public static func lines(
        for state: GuardState,
        report: GeoProbeReport,
        timeZone: TimeZone = .current
    ) -> [StatusLine] {
        var lines: [StatusLine] = []

        // Адрес есть только когда ipinfo ответил: показывать «неизвестен» рядом
        // с текстом отказа значило бы повторять одно и то же дважды.
        if let ip = report.ip {
            lines.append(StatusLine(key: "IP", value: ip))
        }

        lines.append(StatusLine(key: "ipinfo", value: text(for: report.ipinfo)))
        lines.append(StatusLine(
            key: report.confirmSource?.rawValue ?? confirmationLabel,
            value: text(for: report.confirmation)
        ))

        // Про сеть спрашиваем системный монитор, и строка нужна лишь тогда,
        // когда что-то не сложилось: это ответ на «мой VPN виноват или сервис?».
        if !report.isFullyAnswered {
            lines.append(StatusLine(key: "сеть", value: report.hasNetworkPath ? "есть" : "нет"))
        }

        lines.append(StatusLine(key: "Проверено", value: time(report.checkedAt, in: timeZone)))
        return lines
    }

    private static func text(for outcome: GeoProbeReport.SourceOutcome) -> String {
        switch outcome {
        case .answered(let value): return value
        case .failed(let failure): return failure.displayText
        case .notRequested: return "не запрашивалось"
        }
    }

    private static func time(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    private static func knownReading(for state: GuardState, reading: GeoReading?) -> GeoReading? {
        if case .unsafe(let reason) = state, case .geoUnavailable = reason { return nil }
        if case .safe(let current) = state { return current ?? reading }
        return reading
    }

    public static func detail(for state: GuardState, reading: GeoReading?) -> String? {
        guard knownReading(for: state, reading: reading) != nil else { return nil }
        return lines(for: state, reading: reading)
            .map { "\($0.key): \($0.value)" }
            .joined(separator: " · ")
    }
}
