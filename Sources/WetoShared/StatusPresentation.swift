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

public enum StatusPresentation {

    public static let unknownIP = "неизвестен"
    public static let missingValue = "—"

    public static func title(for state: GuardState) -> String {
        switch state {
        case .disabled: return "Охрана выключена"
        case .safe: return "На страже"
        case .unsafe(let reason): return reason.statusTitle
        }
    }

    public static func lines(for state: GuardState, reading: GeoReading?) -> [StatusLine] {
        let known = knownReading(for: state, reading: reading)

        return [
            StatusLine(key: "IP", value: known?.ip ?? unknownIP),
            StatusLine(key: "ipinfo", value: known?.primaryCountry ?? missingValue),
            StatusLine(key: "ipwhois", value: known?.confirmedCountry ?? missingValue),
        ]
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
