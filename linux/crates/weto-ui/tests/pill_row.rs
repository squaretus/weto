//! Строка цели с кнопкой «Вернуть в терминал» — замером настоящего окна.
//!
//! Чтением CSS и `measure` этого не проверить: высоту кнопке отдаёт ряд при раскладке,
//! а сокращается ли имя, решает ширина, которая досталась ему на самом деле.
//!
//! Всё одним тестом: GTK поднимается на один поток, а `cargo test` раздаёт
//! тесты по разным, и второй `init` уже не получает главный контекст.

use std::time::{Duration, Instant};

use gtk4::glib::MainContext;
use gtk4::prelude::*;
use gtk4::{Label, Orientation, Widget, Window};

use weto_ui::components as ui;
use weto_ui::theme::{self, Theme};

/// Иконка пилюли: сама строка заведомо выше неё, а значит, и выше кнопки по её собственной мере.
const MIN_PILL_HEIGHT: i32 = 32;

fn labels(root: &impl IsA<Widget>) -> Vec<Label> {
    let mut found = Vec::new();
    let mut child = root.as_ref().first_child();
    while let Some(widget) = child {
        child = widget.next_sibling();
        found.extend(labels(&widget));
        if let Ok(label) = widget.downcast::<Label>() {
            found.push(label);
        }
    }
    found
}

fn label(root: &impl IsA<Widget>, text: &str) -> Label {
    labels(root)
        .into_iter()
        .find(|label| label.text() == text)
        .unwrap_or_else(|| panic!("нет подписи «{text}»"))
}

fn settle(widget: &impl IsA<Widget>) {
    let widget = widget.as_ref();
    let context = MainContext::default();
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        while context.iteration(false) {}
        if widget.width() > 0 {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(widget.width() > 0, "окно не разложилось");
}

/// Внешний размер виджета: `width()` и `height()` у GTK4 считают без паддинга и рамки,
/// а на глаз сравниваются именно внешние края.
fn outer(widget: &impl IsA<Widget>) -> (i32, i32) {
    let bounds = widget
        .as_ref()
        .compute_bounds(widget.as_ref())
        .expect("виджет разложен");
    (bounds.width() as i32, bounds.height() as i32)
}

/// Подпись не сжимается: минимальная ширина равна естественной, и досталась ей она.
fn assert_fixed_width(widget: &impl IsA<Widget>, name: &str) {
    let (minimum, natural, _, _) = widget.as_ref().measure(Orientation::Horizontal, -1);
    assert_eq!(minimum, natural, "«{name}» может сжаться");
    assert_eq!(outer(widget).0, natural, "«{name}» получил не свою ширину");
}

/// Окно попапа — как его строит `status_window`.
fn popup(row: &impl IsA<Widget>) -> Window {
    let window = Window::builder()
        .default_width(ui::POPUP_WIDTH)
        .resizable(false)
        .build();
    theme::mark_root(&window);
    let panel = ui::panel();
    panel.set_spacing(ui::SPACE4);
    window.set_child(Some(&panel));
    panel.append(row);
    window.present();
    window
}

#[test]
fn the_row_with_the_button_holds_its_shape_and_only_the_name_shortens() {
    gtk4::init().expect("GTK не поднялся: тестам нужен дисплей, запускать под Xvfb");
    theme::install_styles(Theme::Dark);

    // --- Обычное имя: сокращать нечего, кнопка той же высоты, что пилюля ---
    let accessory = ui::background_label(false);
    let pill = ui::process_pill("claude", None, true, 34, Some(&accessory));
    let button = ui::return_button();
    let row = ui::pill_row(&pill, Some(&button));
    let window = popup(&row);
    settle(&button);

    assert_eq!(window.width(), ui::POPUP_WIDTH, "ширина попапа");
    assert_eq!(
        outer(&pill).1,
        outer(&button).1,
        "пилюля и кнопка одной высоты"
    );
    assert!(outer(&pill).1 > MIN_PILL_HEIGHT);
    assert_eq!(button.valign(), gtk4::Align::Fill);

    let name = label(&pill, "claude");
    assert!(!name.layout().is_ellipsized(), "место есть — имя целиком");
    assert_fixed_width(&label(&pill, "terminal"), "terminal");
    assert_fixed_width(&label(&pill, "в фоне"), "в фоне");
    assert_fixed_width(&label(&pill, "+34"), "+34");
    assert_fixed_width(&button, "Вернуть в терминал");
    assert_eq!(
        outer(&pill).0 + ui::SPACE2 + outer(&button).0,
        outer(&row).0
    );
    window.destroy();

    // --- Длинное имя: сокращается только оно, и окно его не распирает ---
    let long_name = "очень-длинное-имя-цели-".repeat(12);
    let accessory = ui::background_label(false);
    let pill = ui::process_pill(&long_name, None, true, 34, Some(&accessory));
    let button = ui::return_button();
    let row = ui::pill_row(&pill, Some(&button));
    let window = popup(&row);
    settle(&button);

    assert_eq!(
        window.width(),
        ui::POPUP_WIDTH,
        "длинное имя распирает окно"
    );
    assert_eq!(outer(&pill).1, outer(&button).1);
    let name = label(&pill, &long_name);
    assert!(name.layout().is_ellipsized(), "места нет — имя сокращено");
    assert_fixed_width(&label(&pill, "terminal"), "terminal");
    assert_fixed_width(&label(&pill, "в фоне"), "в фоне");
    assert_fixed_width(&label(&pill, "+34"), "+34");
    assert_fixed_width(&button, "Вернуть в терминал");
    window.destroy();

    // --- Кнопка ушла, осталась подсказка: она не сжимается, а имя снова сокращается ---
    let accessory = ui::background_label(true);
    let pill = ui::process_pill(&long_name, None, true, 34, Some(&accessory));
    let row = ui::pill_row(&pill, None);
    let window = popup(&row);
    settle(&pill);

    assert_eq!(
        window.width(),
        ui::POPUP_WIDTH,
        "длинное имя распирает окно"
    );
    assert_fixed_width(&label(&pill, "в фоне: введите fg"), "в фоне: введите fg");
    window.destroy();
}
