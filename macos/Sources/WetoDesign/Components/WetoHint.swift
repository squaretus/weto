import SwiftUI

/// Значок «?», открывающий пояснение по нажатию. Пояснение к смыслу настройки стоит
/// сразу после её названия; пояснение к формату ввода — в конце поля
/// (`wetoFieldHint`), и только пока поле пустое: кто начал набирать, подсказку
/// уже прочитал, а стерев ввод, увидит её снова.
///
/// По нажатию, а не по наведению: системная подсказка появляется с задержкой
/// и острыми углами. Здесь пояснение открывается сразу, в скруглённом окне
/// цвета карточки. Сам значок кнопкой не выглядит — фона нет, — но отвечает
/// на наведение цветом и курсором, а пока пояснение открыто, горит акцентом.
public struct WetoHint: View {

    private let text: String

    @State private var isPresented = false
    @State private var isHovered = false

    @Environment(\.colorScheme) private var scheme

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(iconColor)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { isHovered = $0 }
        .accessibilityLabel("Пояснение")
        .accessibilityHint(text)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Text(text)
                .font(WetoTokens.value)
                .foregroundStyle(WetoTokens.ink.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: Self.bubbleWidth, alignment: .leading)
                .padding(WetoTokens.space4)
                .presentationBackground(WetoTokens.card.resolve(scheme))
                .environment(\.colorScheme, scheme)
        }
    }

    /// Ширина окна пояснения: строка в ~40 знаков читается без бега глазами.
    static let bubbleWidth: CGFloat = 264

    private var iconColor: Color {
        if isPresented { return WetoTokens.violet.resolve(scheme) }
        return (isHovered ? WetoTokens.dim : WetoTokens.faint).resolve(scheme)
    }

    /// Значок в поле виден, пока в поле ничего не набрано.
    public static func isShown(forFieldText text: String) -> Bool {
        text.isEmpty
    }
}

extension View {

    /// Пояснение к формату ввода: значок «?» в конце поля, пока поле пустое.
    /// Отступ — тот же, что у текста поля в `WetoFieldStyle`.
    public func wetoFieldHint(_ hint: String, fieldText: String) -> some View {
        overlay(alignment: .trailing) {
            if WetoHint.isShown(forFieldText: fieldText) {
                WetoHint(hint)
                    .padding(.trailing, 11)
            }
        }
    }
}
