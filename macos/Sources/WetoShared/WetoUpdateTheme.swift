import SwiftUI
import AppKit
import WetoDesign
import UpdateKitUI

public extension AppTheme {
    /// Тема приложения в терминах SwiftUI: цвета токенов разрешаются по ней.
    var colorScheme: ColorScheme {
        self == .light ? .light : .dark
    }
}

/// Весь стиль окна обновления в одном месте: пакет рисует, weto решает, чем.
/// Перенос механизма в другой проект — это новый такой файл, а не правка окна.
@MainActor
public enum WetoUpdateTheme {

    /// Ширина под самый длинный ряд кнопок: «Пропустить версию», «Напомнить позже»
    /// и «Обновить» должны помещаться целиком, без сокращения подписей.
    ///
    /// Значение не на глаз: ряду нужно 507 pt по замеру живых контролов, и это
    /// сверяется тестом. Прежние 480 pt обещали то же самое, но обещание никто
    /// не проверял — и «Обновить» уезжала за правый край. Взято 513: на шаге
    /// сетки 3 pt, промежутки выходят по 27 pt, и остаётся запас на расхождение
    /// замера с раскладкой внутри ряда.
    public static let width: CGFloat = 513

    public static func make(for appTheme: AppTheme) -> UpdateTheme {
        let scheme = appTheme.colorScheme

        return UpdateTheme(
            background: WetoTokens.shell.resolve(scheme),
            text: WetoTokens.ink.resolve(scheme),
            secondaryText: WetoTokens.dim.resolve(scheme),
            accent: WetoTokens.violet.resolve(scheme),
            cornerRadius: WetoTokens.radiusPanel,
            width: width,
            titleFont: WetoTokens.status,
            bodyFont: WetoTokens.value,
            icon: WetoAppIcon.image(for: scheme),
            primaryButton: { title, action in
                AnyView(
                    Button(title, action: action)
                        .buttonStyle(WetoPillButtonStyle(.primary))
                        .environment(\.colorScheme, scheme)
                )
            },
            secondaryButton: { title, action in
                AnyView(
                    Button(title, action: action)
                        .buttonStyle(WetoPillButtonStyle(.ghost))
                        .environment(\.colorScheme, scheme)
                )
            },
            menuButton: { title, items in
                AnyView(
                    WetoMenuButton(title) {
                        ForEach(items) { item in
                            Button(item.title, action: item.action)
                        }
                    }
                    .environment(\.colorScheme, scheme)
                )
            }
        )
    }
}
