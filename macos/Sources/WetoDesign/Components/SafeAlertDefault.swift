import AppKit

extension NSAlert {

    /// Подтверждение необратимого: первая кнопка — действие, вторая — безопасный исход.
    /// Enter нажимает безопасную кнопку, а не действие: случайный Enter в «Удалить Weto?»
    /// или «Удалить всё равно» ничего не удаляет. Так же ведут себя диалоги на Linux.
    /// Кнопку действия система рисует как деструктивную.
    public func makeSafeButtonDefault() {
        guard buttons.count >= 2 else { return }
        buttons[0].keyEquivalent = ""
        buttons[0].hasDestructiveAction = true
        buttons[1].keyEquivalent = "\r"
    }
}
