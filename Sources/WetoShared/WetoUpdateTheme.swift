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
    public static let width: CGFloat = 480

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
                    Menu {
                        ForEach(items) { item in
                            Button(item.title, action: item.action)
                        }
                    } label: {
                        Text(title)
                            .font(WetoTokens.button)
                            .foregroundStyle(WetoTokens.ink.resolve(scheme))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .environment(\.colorScheme, scheme)
                )
            }
        )
    }
}
