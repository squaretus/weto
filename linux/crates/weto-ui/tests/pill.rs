//! Пилюля живой цели, значок паузы и строка показаний — порт `WetoProcessPill`,
//! `WetoPauseBadge` и показаний `StatusPopupView` с macOS.
//!
//! Всё одним тестом: GTK поднимается на один поток, а `cargo test` раздаёт
//! тесты по разным, и второй `init` уже не получает главный контекст.

use std::time::{Duration, UNIX_EPOCH};

use gtk4::prelude::*;
use gtk4::{Image, Label, Orientation, Widget, Window};

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

fn children(root: &impl IsA<Widget>) -> Vec<Widget> {
    let mut found = Vec::new();
    let mut child = root.as_ref().first_child();
    while let Some(widget) = child {
        child = widget.next_sibling();
        found.push(widget);
    }
    found
}

#[test]
fn the_pill_is_one_line_and_the_hint_stands_outside_the_capsule() {
    gtk4::init().expect("GTK не поднялся: тестам нужен дисплей, запускать под Xvfb");
    theme::install_styles(Theme::Dark);

    // Без окна виджет не получает стилевого контекста, и паддинги из CSS
    // в замер не попадают.
    let window = Window::new();
    theme::mark_root(&window);
    let column = gtk4::Box::new(Orientation::Vertical, 0);
    window.set_child(Some(&column));

    // --- Значок паузы: (i) — снаружи янтарной капсулы, цветом `faint` ---
    let now = UNIX_EPOCH + Duration::from_secs(1_000);
    let hint = "Процесс вернулся в фон. Откройте терминал и введите fg";
    let (badge, button) =
        ui::pause_badge(Some(now + Duration::from_secs(43)), now, Some(hint), true);
    assert!(button.is_some());

    let row = children(&badge);
    let capsule = &row[0];
    assert!(
        capsule.has_css_class("weto-pause-badge"),
        "первой идёт капсула"
    );
    assert!(
        descendants(capsule)
            .iter()
            .all(|widget| widget.tooltip_text().as_deref() != Some(hint)),
        "(i) не имеет права стоять внутри янтарной капсулы"
    );
    let info = row[1]
        .clone()
        .downcast::<Image>()
        .expect("за капсулой стоит (i)");
    assert_eq!(info.tooltip_text().as_deref(), Some(hint));
    assert!(
        info.has_css_class("weto-hint"),
        "(i) цветом faint, как на macOS"
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
    let deadline = Some(now + Duration::from_secs(43));
    let (short_badge, _) = ui::pause_badge(deadline, now, Some(hint), true);
    let short = ui::process_pill("claude", None, true, 3, Some(&short_badge));
    column.append(&short);
    assert_eq!(minimum(&pill), minimum(&short), "имя распирает пилюлю");

    // Стоящая цель без кнопки «Показать терминал» помещается в попап целиком.
    let (quiet_badge, _) = ui::pause_badge(deadline, now, Some(hint), false);
    let quiet = ui::process_pill(&long_name, None, true, 3, Some(&quiet_badge));
    column.append(&quiet);
    assert!(
        minimum(&quiet) <= ui::POPUP_WIDTH - 2 * ui::SPACE4,
        "пилюля шире попапа: {}",
        minimum(&quiet)
    );

    // Цель-приложение (ярлык) метки не несёт.
    let app = ui::process_pill("Firefox", None, false, 0, None);
    assert!(labels(&app).iter().all(|label| label.text() != "terminal"));

    // --- Показания выделяются мышью ---
    let reading = ui::data_row("IP", Some("203.0.113.28"));
    assert!(labels(&reading).iter().all(|label| label.is_selectable()));
}
