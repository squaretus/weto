//! Пилюля живой цели, значок паузы, подпись цели в фоне и строка показаний — порт
//! `WetoProcessPill`, `WetoPauseBadge`, `WetoBackgroundLabel` и показаний `StatusPopupView`.
//!
//! Всё одним тестом: GTK поднимается на один поток, а `cargo test` раздаёт
//! тесты по разным, и второй `init` уже не получает главный контекст.

use std::time::{Duration, UNIX_EPOCH};

use gtk4::prelude::*;
use gtk4::{Label, Orientation, Widget, Window};

use weto_ui::components as ui;
use weto_ui::theme::{self, Theme};

fn descendants(root: &impl IsA<Widget>) -> Vec<Widget> {
    let mut found = Vec::new();
    let mut child = root.as_ref().first_child();
    while let Some(widget) = child {
        child = widget.next_sibling();
        found.extend(descendants(&widget));
        found.push(widget);
    }
    found
}

fn labels(root: &impl IsA<Widget>) -> Vec<Label> {
    descendants(root)
        .into_iter()
        .filter_map(|widget| widget.downcast::<Label>().ok())
        .collect()
}

#[test]
fn the_pill_is_one_line_and_the_badge_is_only_a_countdown() {
    gtk4::init().expect("GTK не поднялся: тестам нужен дисплей, запускать под Xvfb");
    theme::install_styles(Theme::Dark);

    // Без окна виджет не получает стилевого контекста, и паддинги из CSS
    // в замер не попадают.
    let window = Window::new();
    theme::mark_root(&window);
    let column = gtk4::Box::new(Orientation::Vertical, 0);
    window.set_child(Some(&column));

    // --- Значок паузы: только капсула с отсчётом, кнопок и (i) больше нет ---
    let now = UNIX_EPOCH + Duration::from_secs(1_000);
    let deadline = Some(now + Duration::from_secs(43));
    let badge = ui::pause_badge(deadline, now);
    assert!(
        badge.has_css_class("weto-pause-badge"),
        "значок и есть капсула"
    );
    assert!(
        descendants(&badge)
            .iter()
            .all(|widget| !widget.is::<gtk4::Button>()),
        "на паузе цели не возвращаются: кнопки рядом с отсчётом нет"
    );
    let countdown: Vec<String> = labels(&badge)
        .iter()
        .map(|label| label.text().to_string())
        .collect();
    assert_eq!(countdown, ["43 с"]);

    // --- Подпись цели в фоне: янтарным, с командой — когда кнопки уже нет ---
    let plain = ui::background_label(false);
    let with_command = ui::background_label(true);
    assert_eq!(labels(&plain)[0].text(), "в фоне");
    assert_eq!(labels(&with_command)[0].text(), "в фоне: введите fg");
    assert!(labels(&with_command)[0].has_css_class("weto-background-label"));

    // --- Подсказка под строкой: дословно как на macOS ---
    assert_eq!(
        ui::return_failed_hint().text(),
        "Не удалось вернуть автоматически. В терминале введите fg"
    );

    // --- Пилюля: одна строка, обрезка в середине, метка `terminal` ---
    let long_name = "очень-длинное-имя-цели-".repeat(12);
    let pill = ui::process_pill(&long_name, None, true, 3, Some(&badge));
    column.append(&pill);

    let texts: Vec<String> = labels(&pill)
        .iter()
        .filter(|label| !label.is_ancestor(&badge))
        .map(|label| label.text().to_string())
        .collect();
    assert_eq!(
        texts,
        [long_name.as_str(), "terminal", "+3"],
        "в пилюле одна строка: имя, метка и счётчик, без пути под именем"
    );

    let title = labels(&pill)
        .into_iter()
        .find(|label| label.text() == long_name)
        .expect("имя цели");
    assert_eq!(title.ellipsize(), gtk4::pango::EllipsizeMode::Middle);
    assert!(!title.wraps());

    let kind = labels(&pill)
        .into_iter()
        .find(|label| label.text() == "terminal")
        .expect("метка terminal");
    assert!(
        kind.has_css_class("weto-data-key"),
        "шрифт данных цветом faint"
    );

    // Длинное имя не имеет права распирать попап: минимальная ширина пилюли
    // от длины имени не зависит — имя сжимается до многоточия, а ширину
    // задают значок, метки и аксессуар.
    let minimum = |pill: &gtk4::Box| pill.measure(Orientation::Horizontal, -1).0;
    let short_badge = ui::pause_badge(deadline, now);
    let short = ui::process_pill("claude", None, true, 3, Some(&short_badge));
    column.append(&short);
    assert_eq!(minimum(&pill), minimum(&short), "имя распирает пилюлю");

    // Стоящая цель помещается в попап целиком.
    let quiet_badge = ui::pause_badge(deadline, now);
    let quiet = ui::process_pill(&long_name, None, true, 3, Some(&quiet_badge));
    column.append(&quiet);
    assert!(
        minimum(&quiet) <= ui::POPUP_WIDTH - 2 * ui::SPACE4,
        "пилюля шире попапа: {}",
        minimum(&quiet)
    );

    // И цель в фоне с кнопкой рядом — самая широкая строка попапа. Подпись с командой
    // рядом с кнопкой не встречается: она появляется, когда кнопка уже ушла.
    let wide_label = ui::background_label(false);
    let wide = ui::process_pill(&long_name, None, true, 3, Some(&wide_label));
    let button = ui::return_button();
    let wide_row = ui::pill_row(&wide, Some(&button));
    column.append(&wide_row);
    let width = wide_row.measure(Orientation::Horizontal, -1).0;
    assert!(
        width <= ui::POPUP_WIDTH - 2 * ui::SPACE4,
        "строка с кнопкой шире попапа: {width}"
    );

    // Цель-приложение (ярлык) метки не несёт.
    let app = ui::process_pill("Firefox", None, false, 0, None);
    assert!(labels(&app).iter().all(|label| label.text() != "terminal"));

    // Подпись с командой без кнопки помещается тоже.
    let expired_label = ui::background_label(true);
    let expired = ui::process_pill(&long_name, None, true, 3, Some(&expired_label));
    column.append(&expired);
    assert!(
        minimum(&expired) <= ui::POPUP_WIDTH - 2 * ui::SPACE4,
        "пилюля с подсказкой шире попапа: {}",
        minimum(&expired)
    );

    // --- Показания выделяются мышью ---
    let reading = ui::data_row("IP", Some("203.0.113.28"));
    assert!(labels(&reading).iter().all(|label| label.is_selectable()));
}
