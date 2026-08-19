import SwiftUI

extension Color {

    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

public struct WetoColor: Equatable, Sendable {
    public let dark: Color
    public let light: Color

    public init(dark: Color, light: Color) {
        self.dark = dark
        self.light = light
    }

    public func resolve(_ scheme: ColorScheme) -> Color {
        scheme == .light ? light : dark
    }
}

public enum WetoTokens {

    public static let shell = WetoColor(dark: Color(hex: 0x17161D), light: Color(hex: 0xE7E4F1))
    public static let card = WetoColor(dark: Color(hex: 0x201F28), light: .white)
    public static let sunk = WetoColor(dark: Color(hex: 0x2A2833), light: Color(hex: 0xEEEBFA))

    public static let line = WetoColor(
        dark: Color(white: 1, opacity: 0.08),
        light: Color(hex: 0x1C143C, opacity: 0.16)
    )
    public static let sunkLine = WetoColor(
        dark: .clear,
        light: Color(hex: 0x1C143C, opacity: 0.10)
    )

    public static let ink = WetoColor(dark: Color(hex: 0xF4F2FB), light: Color(hex: 0x16102C))
    public static let dim = WetoColor(
        dark: Color(hex: 0xF4F2FB, opacity: 0.66),
        light: Color(hex: 0x16102C, opacity: 0.72)
    )
    public static let faint = WetoColor(
        dark: Color(hex: 0xF4F2FB, opacity: 0.40),
        light: Color(hex: 0x16102C, opacity: 0.52)
    )

    public static let violet = WetoColor(dark: Color(hex: 0x8B7BFF), light: Color(hex: 0x6244F0))
    public static let green = WetoColor(dark: Color(hex: 0x46D09B), light: Color(hex: 0x0E8A5B))
    public static let amber = WetoColor(dark: Color(hex: 0xF2B544), light: Color(hex: 0x9D6A09))
    public static let red = WetoColor(dark: Color(hex: 0xFF6B81), light: Color(hex: 0xD43A53))

    public static let panelShadow = Color(hex: 0x140A32, opacity: 0.32)
    public static let cardShadow = WetoColor(
        dark: .clear,
        light: Color(hex: 0x180E3C, opacity: 0.08)
    )

    public static let space1: CGFloat = 3
    public static let space2: CGFloat = 6
    public static let space3: CGFloat = 9
    public static let space4: CGFloat = 12
    public static let space5: CGFloat = 18

    public static let radiusPanel: CGFloat = 20
    public static let radiusCard: CGFloat = 15
    public static let radiusControl: CGFloat = 12
    public static let radiusPill: CGFloat = 11
    public static let radiusTile: CGFloat = 10

    public static let popupWidth: CGFloat = 352
    public static let windowWidth: CGFloat = 500
    public static let windowHeight: CGFloat = 640
    public static let controlHeight: CGFloat = 32

    public static let status: Font = .system(size: 15, weight: .semibold)
    public static let label: Font = .system(size: 13, weight: .medium)
    public static let value: Font = .system(size: 13)
    public static let caption: Font = .system(size: 12)
    public static let data: Font = .system(size: 12).monospacedDigit()
    public static let cardCap: Font = .system(size: 11, weight: .semibold)
    public static let diagnostics: Font = .system(size: 11).monospacedDigit()
    public static let button: Font = .system(size: 13, weight: .semibold)
    public static let segment: Font = .system(size: 12, weight: .medium)
}

public enum StatusTone: Equatable, Sendable {
    case ok
    case degraded
    case blocked
    case off

    public var color: WetoColor {
        switch self {
        case .ok: return WetoTokens.green
        case .degraded: return WetoTokens.amber
        case .blocked: return WetoTokens.red
        case .off: return WetoTokens.faint
        }
    }
}
