import SwiftUI
import AppKit
import WetoDesign
import UpdateKitUI

/// Весь стиль окна обновления в одном месте: пакет рисует, weto решает, чем.
/// Перенос механизма в другой проект — это новый такой файл, а не правка окна.
@MainActor
public enum WetoUpdateTheme {

    public static let width: CGFloat = 420

    public static func make(for appTheme: AppTheme) -> UpdateTheme {
        let scheme: ColorScheme = appTheme == .light ? .light : .dark

        return UpdateTheme(
            background: WetoTokens.shell.resolve(scheme),
            text: WetoTokens.ink.resolve(scheme),
            secondaryText: WetoTokens.dim.resolve(scheme),
            accent: WetoTokens.violet.resolve(scheme),
            cornerRadius: WetoTokens.radiusPanel,
            width: width,
            titleFont: WetoTokens.status,
            bodyFont: WetoTokens.value,
            icon: Image(nsImage: NSApplication.shared.applicationIconImage),
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
