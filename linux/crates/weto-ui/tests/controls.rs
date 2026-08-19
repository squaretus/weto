//! Контролы одного ряда обязаны стоять на одной высоте.
//!
//! Проверка идёт замером живых виджетов, а не чтением CSS: высота пилюли
//! складывается из `min-height`, паддинга и рамки, и ошибка в любом из трёх
//! слагаемых видна только в сумме. Ровно так ряд кнопок в окне обновления
//! и разъехался: у приглушённой кнопки рамка была, у первичной — нет.
//!
//! Всё одним тестом: GTK поднимается на один поток, а `cargo test` раздаёт
//! тесты по разным, и второй `init` уже не получает главный контекст.

use gtk4::prelude::*;
use gtk4::{Orientation, Widget, Window};

use weto_ui::components as ui;
use weto_ui::theme::{self, Theme};

/// Значение токена `controlHeight` из `shared/tokens/design-tokens.json`.
/// Дублируется здесь намеренно: тест сторожит именно расхождение с каноном.
const CONTROL_HEIGHT: i32 = 32;

fn height(widget: &impl IsA<Widget>) -> i32 {
    let (_, natural, _, _) = widget.measure(Orientation::Vertical, -1);
    natural
}

#[test]
fn every_control_of_a_row_stands_at_one_height() {
    gtk4::init().expect("GTK не поднялся: тестам нужен дисплей, запускать под Xvfb");
    theme::install_styles(Theme::Dark);

    // Без окна виджет не получает стилевого контекста, и CSS в замер не попадает.
    let window = Window::new();
    theme::mark_root(&window);
    let row = ui::action_row();
    window.set_child(Some(&row));

    let update = ui::primary_button("Обновить");
    let skip = ui::muted_button("Пропустить эту версию");
    let clear = ui::destructive_button("Очистить журнал");
    let picker = ui::dropdown();
    let field = ui::entry("Код страны (RU), IP или CIDR");

    row.append(&update);
    row.append(&skip);
    row.append(&clear);
    row.append(&picker);
    row.append(&field);

    let measured = [
        ("обновить", height(&update)),
        ("пропустить", height(&skip)),
        ("очистить", height(&clear)),
        ("выпадающий список", height(&picker)),
        ("поле ввода", height(&field)),
    ];

    for (name, value) in measured {
        assert_eq!(
            value, CONTROL_HEIGHT,
            "«{name}» выпадает из ряда: {measured:?}"
        );
    }
}
