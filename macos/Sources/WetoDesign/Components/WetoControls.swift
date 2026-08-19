import SwiftUI

public struct WetoSegmentedControl<Value: Hashable>: View {

    private let options: [(value: Value, title: String)]
    @Binding private var selection: Value

    @Environment(\.colorScheme) private var scheme

    public init(selection: Binding<Value>, options: [(value: Value, title: String)]) {
        self._selection = selection
        self.options = options
    }

    public var body: some View {
        HStack(spacing: WetoTokens.space1) {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(WetoTokens.segment)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, WetoTokens.space2)
                        .foregroundStyle(
                            option.value == selection
                                ? Color.white
                                : WetoTokens.dim.resolve(scheme)
                        )
                        .background(
                            RoundedRectangle(cornerRadius: WetoTokens.radiusTile, style: .continuous)
                                .fill(
                                    option.value == selection
                                        ? WetoTokens.violet.resolve(scheme)
                                        : .clear
                                )
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(option.value == selection ? [.isSelected] : [])
            }
        }
        .padding(WetoTokens.space1)
        .background(
            RoundedRectangle(cornerRadius: WetoTokens.radiusControl, style: .continuous)
                .fill(WetoTokens.sunk.resolve(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: WetoTokens.radiusControl, style: .continuous)
                .strokeBorder(WetoTokens.sunkLine.resolve(scheme), lineWidth: 1)
        )
    }
}

public struct WetoPillButtonStyle: ButtonStyle {

    public enum Kind: Equatable, Sendable {
        case primary
        case ghost
        case danger
    }

    private let kind: Kind
    private let expands: Bool

    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled

    public init(_ kind: Kind, expands: Bool = false) {
        self.kind = kind
        self.expands = expands
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(WetoTokens.button)
            .foregroundStyle(foreground)
            .padding(.horizontal, 15)
            // Высота — из токена, а не из суммы шрифта и вертикального паддинга:
            // подписи в ряду разной длины и с разными выносными, и кнопки
            // выходили разной высоты. Ряд обязан стоять на одной линии.
            .frame(height: WetoTokens.controlHeight)
            .frame(maxWidth: expands ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: WetoTokens.radiusPill, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: WetoTokens.radiusPill, style: .continuous)
                    .strokeBorder(border, lineWidth: kind == .ghost ? 1 : 0)
            )
            .opacity(opacity(pressed: configuration.isPressed))
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .ghost: return WetoTokens.ink.resolve(scheme)
        case .danger: return WetoTokens.red.resolve(scheme)
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return WetoTokens.violet.resolve(scheme)
        case .ghost: return WetoTokens.sunk.resolve(scheme)
        case .danger: return WetoTokens.red.resolve(scheme).opacity(0.16)
        }
    }

    private var border: Color {
        kind == .ghost ? WetoTokens.line.resolve(scheme) : .clear
    }

    private func opacity(pressed: Bool) -> Double {
        if !isEnabled { return 0.4 }
        return pressed ? 0.7 : 1
    }
}

/// Кнопка-пилюля, раскрывающая меню: «Напомнить позже» в окне обновления.
///
/// Меню, а не `Picker`: пункты — это действия с разным сроком, а не выбор
/// значения. Системный индикатор погашен и заменён своей стрелкой: у
/// `.borderlessButton` его рисует AppKit поверх текста, без подложки и без
/// нашей высоты, и контрол выпадал из ряда кнопок.
public struct WetoMenuButton<Items: View>: View {

    private let title: String
    private let items: () -> Items

    public init(_ title: String, @ViewBuilder items: @escaping () -> Items) {
        self.title = title
        self.items = items
    }

    public var body: some View {
        Menu {
            items()
        } label: {
            HStack(spacing: WetoTokens.space2) {
                Text(title)
                Image(systemName: "chevron.down")
                    .font(WetoTokens.segment)
            }
        }
        .menuIndicator(.hidden)
        .menuStyle(.button)
        .buttonStyle(WetoPillButtonStyle(.ghost))
        .fixedSize()
    }
}

public struct WetoTileButtonStyle: ButtonStyle {

    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.white)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: WetoTokens.radiusTile, style: .continuous)
                    .fill(WetoTokens.violet.resolve(scheme))
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

public struct WetoIconButtonStyle: ButtonStyle {

    @Environment(\.colorScheme) private var scheme

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(WetoTokens.faint.resolve(scheme))
            .padding(WetoTokens.space1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

public struct WetoFieldStyle: TextFieldStyle {

    @Environment(\.colorScheme) private var scheme

    public init() {}

    public func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(WetoTokens.value)
            .foregroundStyle(WetoTokens.ink.resolve(scheme))
            .padding(.horizontal, 11)
            // Поле стоит в строке рядом с кнопкой и обязано быть с ней одной высоты.
            .frame(height: WetoTokens.controlHeight)
            .background(
                RoundedRectangle(cornerRadius: WetoTokens.radiusPill, style: .continuous)
                    .fill(WetoTokens.sunk.resolve(scheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: WetoTokens.radiusPill, style: .continuous)
                    .strokeBorder(WetoTokens.sunkLine.resolve(scheme), lineWidth: 1)
            )
    }
}

public struct StatusShield: View {

    private let tone: StatusTone

    @Environment(\.colorScheme) private var scheme

    public init(tone: StatusTone) {
        self.tone = tone
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(tone.color.resolve(scheme))
            .frame(width: 32, height: 32)
            .overlay(
                Image(systemName: "shield")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.white)
            )
            .accessibilityHidden(true)
    }
}
