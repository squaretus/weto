import AppKit

extension NSAlert {

    /// Подтверждение закрытия или удаления: первая кнопка — действие, вторая — отказ.
    /// Enter не нажимает ничего: решение принимается только явным нажатием. Кнопки
    /// по умолчанию нет, поэтому система не красит ни одну акцентом — обе одного
    /// вида. Esc — стандартная отмена: нажимает отказ (по-русски подписанную кнопку
    /// AppKit сам Esc не назначает). Так же ведут себя диалоги на Linux.
    public func makeConfirmationButtons() {
        guard buttons.count >= 2 else { return }
        buttons[0].keyEquivalent = ""
        buttons[1].keyEquivalent = "\u{1b}"
    }
}
