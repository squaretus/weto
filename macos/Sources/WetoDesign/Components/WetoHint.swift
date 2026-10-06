import SwiftUI

/// Значок «?» с пояснением при наведении. Пояснение к смыслу настройки стоит
/// сразу после её названия; пояснение к формату ввода — в конце поля
/// (`wetoFieldHint`), и только пока поле пустое: кто начал набирать, подсказку
/// уже прочитал, а стерев ввод, увидит её снова.
public struct WetoHint: View {

    private let text: String

    @Environment(\.colorScheme) private var scheme

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.system(size: 12))
            .foregroundStyle(WetoTokens.faint.resolve(scheme))
            .help(text)
            .accessibilityLabel(text)
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
