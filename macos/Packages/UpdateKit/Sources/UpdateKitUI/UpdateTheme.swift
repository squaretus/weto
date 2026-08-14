import SwiftUI

/// Как окно обновления выглядит в конкретном приложении.
///
/// Не протокол с associated type, а структура значений и построителей: так
/// адаптер проекта — это одно значение на три десятка строк, а вёрстка окна
/// остаётся в пакете и переносится без правок.
@MainActor
public struct UpdateTheme {

    public var background: Color
    public var text: Color
    public var secondaryText: Color
    public var accent: Color
    public var cornerRadius: CGFloat
    public var width: CGFloat

    public var titleFont: Font
    public var bodyFont: Font

    public var icon: Image

    /// Основная кнопка («Обновить»).
    public var primaryButton: @MainActor (String, @escaping () -> Void) -> AnyView

    /// Вторичная кнопка («Пропустить версию», «Открыть страницу релиза»).
    public var secondaryButton: @MainActor (String, @escaping () -> Void) -> AnyView

    /// Кнопка с меню («Напомнить позже» и три срока).
    public var menuButton: @MainActor (String, [UpdateMenuItem]) -> AnyView

    public init(
        background: Color,
        text: Color,
        secondaryText: Color,
        accent: Color,
        cornerRadius: CGFloat,
        width: CGFloat,
        titleFont: Font,
        bodyFont: Font,
        icon: Image,
        primaryButton: @escaping @MainActor (String, @escaping () -> Void) -> AnyView,
        secondaryButton: @escaping @MainActor (String, @escaping () -> Void) -> AnyView,
        menuButton: @escaping @MainActor (String, [UpdateMenuItem]) -> AnyView
    ) {
        self.background = background
        self.text = text
        self.secondaryText = secondaryText
        self.accent = accent
        self.cornerRadius = cornerRadius
        self.width = width
        self.titleFont = titleFont
        self.bodyFont = bodyFont
        self.icon = icon
        self.primaryButton = primaryButton
        self.secondaryButton = secondaryButton
        self.menuButton = menuButton
    }
}

/// Пункт меню отсрочки. Отдельный тип, а не кортеж: `ForEach` нужен `Identifiable`.
public struct UpdateMenuItem: Identifiable {
    public let id: Int
    public let title: String
    public let action: () -> Void

    public init(id: Int, title: String, action: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.action = action
    }
}
