import SwiftUI

/// Кнопка удаления строки списка. Раньше одна и та же корзина с одинаковыми
/// стилем и размером дублировалась в карточках целей и чёрного списка.
public struct WetoDeleteRowAction: View {

    private let label: String
    private let hint: String
    private let action: () -> Void

    public init(label: String, hint: String, action: @escaping () -> Void) {
        self.label = label
        self.hint = hint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 15))
        }
        .buttonStyle(WetoIconButtonStyle())
        .accessibilityLabel(label)
        .help(hint)
    }
}
