import SwiftUI

extension Color {
    /// Инициализация из 0xRRGGBB.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Цвет, зависящий от темы. Резолвится явно, а не через `Color(nsColor:)`,
/// чтобы одно и то же значение работало и в SwiftUI, и при отрисовке в NSImage.
public struct AdaptiveColor: Equatable, Sendable {
    public let dark: Color
    public let light: Color

    public init(dark: Color, light: Color) {
        self.dark = dark
        self.light = light
    }

    public func resolve(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? dark : light
    }
}

/// Палитра, унаследованная от проекта blik — приложения должны выглядеть роднёй.
public enum WetoPalette {
    public static let accentDark = Color(hex: 0x2FB3B8)
    public static let accentLight = Color(hex: 0x007479)

    public static let statusWarn = Color(hex: 0xFFB300)
    public static let statusError = Color(hex: 0xFF4D6D)
    public static let statusSuccess = Color(hex: 0x00D68F)

    public static let bgDark = Color(hex: 0x0A0D14)
    public static let bgLight = Color(hex: 0xF4F1EB)

    public static let bg = AdaptiveColor(dark: bgDark, light: bgLight)
    public static let accent = AdaptiveColor(dark: accentDark, light: accentLight)
}

/// Дизайн-токены приложения. Цвета — тонкие алиасы на `WetoPalette`,
/// чтобы палитра конфигурировалась из одного места.
public enum DesignTokens {

    // MARK: - Цвета

    public static let accent = WetoPalette.accent
    public static let green = WetoPalette.statusSuccess
    public static let amber = WetoPalette.statusWarn
    public static let red = WetoPalette.statusError

    public static let textSecondary = AdaptiveColor(
        dark: Color.white.opacity(0.65),
        light: Color.black.opacity(0.55)
    )
    public static let textTertiary = AdaptiveColor(
        dark: Color.white.opacity(0.45),
        light: Color.black.opacity(0.45)
    )

    // MARK: - Типографика

    /// Единый primary-шрифт: метки, тело, кнопки.
    public static let fontPrimary: Font = .system(size: 13, weight: .regular)
    public static let fontPrimaryMedium: Font = .system(size: 13, weight: .medium)
    public static let fontSecondary: Font = .system(size: 11, weight: .regular)
}
