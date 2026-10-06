//! Стили обязаны грузиться без единой ошибки парсера.
//!
//! Дешёвая защита от опечатки в сгенерированном CSS: GTK на битое правило
//! не падает, он его молча пропускает — и компонент остаётся в дефолтном виде,
//! что заметно далеко не сразу.

use std::cell::Cell;
use std::rc::Rc;

use gtk4::CssProvider;

use weto_ui::theme::{Theme, DARK_CSS, LIGHT_CSS};

fn count_parsing_errors(css: &str) -> usize {
    gtk4::init().expect("GTK не поднялся: тестам нужен дисплей, запускать под xvfb-run");

    let provider = CssProvider::new();
    let errors = Rc::new(Cell::new(0usize));

    let counter = errors.clone();
    #[allow(unused_imports)]
    use gtk4::prelude::*;

    provider.connect_parsing_error(move |_, section, error| {
        eprintln!("ошибка разбора CSS: {error} в {section}");
        counter.set(counter.get() + 1);
    });
    provider.load_from_string(css);

    errors.get()
}

#[test]
fn both_stylesheets_parse_cleanly() {
    assert_eq!(count_parsing_errors(DARK_CSS), 0, "тёмная тема");
    assert_eq!(count_parsing_errors(LIGHT_CSS), 0, "светлая тема");
}

/// Незаполненная подстановка означает опечатку в имени токена. Правило
/// с `{{foo}}` GTK отбрасывает, и компонент остаётся в дефолтном виде.
#[test]
fn no_placeholder_survives_generation() {
    for (name, css) in [("тёмная", DARK_CSS), ("светлая", LIGHT_CSS)] {
        assert!(!css.contains("{{"), "в {name} теме осталась подстановка");
    }
}

/// Переменных CSS в готовых таблицах быть не должно: `var()` появился
/// в GTK 4.16, а пол проекта — 4.14, и на нём такие правила молча отбрасываются.
#[test]
fn no_css_variables_are_used() {
    for (name, css) in [("тёмная", DARK_CSS), ("светлая", LIGHT_CSS)] {
        assert!(
            !css.contains("var(--"),
            "в {name} теме осталась CSS-переменная — на GTK 4.14 она не сработает"
        );
    }
}

/// Обе темы обязаны описывать один и тот же набор правил: расхождение означает
/// элемент, который в одной теме покрашен, а в другой нет.
#[test]
fn both_themes_describe_the_same_rules() {
    let selectors = |css: &str| -> Vec<String> {
        css.lines()
            .map(str::trim)
            .filter(|line| {
                line.starts_with('.') && line.ends_with('{')
                    || line.starts_with('.') && line.ends_with(',')
            })
            .map(|line| line.trim_end_matches(['{', ',']).trim().to_string())
            .collect()
    };

    assert_eq!(selectors(DARK_CSS), selectors(LIGHT_CSS));
    assert!(!selectors(DARK_CSS).is_empty());
}

/// Темы обязаны отличаться: если бы генератор подставил одни и те же значения,
/// светлая тема оказалась бы тёмной, и заметили бы это только глазами.
#[test]
fn the_two_themes_actually_differ() {
    assert_ne!(DARK_CSS, LIGHT_CSS);
    assert_eq!(weto_ui::theme::css_for(Theme::Dark), DARK_CSS);
    assert_eq!(weto_ui::theme::css_for(Theme::Light), LIGHT_CSS);
}

/// Контролы, которым мы задаём заливку, обязаны гасить градиент штатной темы.
///
/// Breeze и Adwaita красят кнопку через `background-image`, и он ложится поверх
/// нашего `background-color`: без сброса кнопка остаётся светлой, а светлый текст
/// на ней исчезает. Ровно этот дефект и был виден на KDE — «Добавить» читалась
/// белым по белому.
#[test]
fn painted_controls_switch_off_the_theme_gradient() {
    // Только то, что GTK рисует как контрол. Карточкам и панелям градиент
    // штатная тема не назначает, и требовать от них сброса было бы шумом.
    const CONTROLS: [&str; 5] = [
        ".weto-primary",
        ".weto-tile-button",
        ".weto-entry",
        ".weto-segments button:checked",
        ".weto-dropdown > button",
    ];

    for (theme, css) in [("тёмная", DARK_CSS), ("светлая", LIGHT_CSS)] {
        for selector in CONTROLS {
            let own = block_for(css, selector)
                .unwrap_or_else(|| panic!("в {theme} теме нет правила {selector}"));

            // Состояние наследует заливку базового правила: у `:checked`
            // своей картинки нет, её гасит `.weto-segments button`.
            let base = selector
                .split_once(':')
                .and_then(|(base, _)| block_for(css, base))
                .unwrap_or_default();
            let block = format!("{own}\n{base}");

            // Сокращённая запись `background: none` гасит картинку тоже.
            let painted = block.contains("background-color");
            let reset =
                block.contains("background-image: none") || block.contains("background: none");

            assert!(
                !painted || reset,
                "{selector} в {theme} теме задаёт заливку, но не гасит градиент темы"
            );
        }
    }
}

/// У панели нет ни рамки, ни радиуса — как у `WetoPanel` на macOS: окно рисует
/// свою рамку само, и вторая скруглённая рамка внутри него читалась как ещё
/// одна карточка, в которую вложено всё окно.
#[test]
fn the_panel_has_no_frame_of_its_own() {
    for (theme, css) in [("тёмная", DARK_CSS), ("светлая", LIGHT_CSS)] {
        let block = block_for(css, ".weto-panel")
            .unwrap_or_else(|| panic!("в {theme} теме нет правила .weto-panel"));
        assert!(
            !block.contains("border"),
            "у .weto-panel осталась рамка ({theme} тема): {block}"
        );
        assert!(block.contains("background-color"), "панель потеряла фон");
    }
}

/// Нажатие гасит контрол до 0.7 — та же непрозрачность, что у пилюль
/// и плитки на macOS (`WetoControls.swift`).
#[test]
fn a_pressed_control_dims_as_on_macos() {
    for selector in [
        ".weto-primary:active",
        ".weto-muted:active",
        ".weto-destructive:active",
        ".weto-dropdown > button:active",
    ] {
        let block =
            block_for(LIGHT_CSS, selector).unwrap_or_else(|| panic!("нет правила {selector}"));
        assert!(
            block.contains("opacity: 0.7;"),
            "{selector} гасится не до 0.7: {block}"
        );
    }
}

/// В светлой теме карточка отделяется от фона тенью `cardShadow`, в тёмной —
/// только цветом (`WetoCard.swift`, `design-system.md`). Правило у тем общее,
/// поэтому в тёмной тень обязана выйти прозрачной, а не исчезнуть из правила.
#[test]
fn the_card_casts_a_shadow_only_in_the_light_theme() {
    let shadow = |css: &str| -> String {
        let block = block_for(css, ".weto-card").expect("нет правила .weto-card");
        block
            .lines()
            .map(str::trim)
            .find(|line| line.starts_with("box-shadow:"))
            .unwrap_or_else(|| panic!("у карточки нет тени: {block}"))
            .to_string()
    };

    assert!(
        shadow(LIGHT_CSS).contains("rgba(24, 14, 60, 0.08)"),
        "в светлой теме у карточки не та тень: {}",
        shadow(LIGHT_CSS)
    );
    assert!(
        shadow(DARK_CSS).contains("rgba(0, 0, 0, 0)"),
        "в тёмной теме у карточки видна тень: {}",
        shadow(DARK_CSS)
    );
}

/// Тело правила вместе с телами правил, где селектор перечислен через запятую.
fn block_for(css: &str, selector: &str) -> Option<String> {
    let css = strip_comments(css);
    let mut found = None;
    for chunk in css.split('}') {
        let Some((head, body)) = chunk.split_once('{') else {
            continue;
        };
        let listed = head
            .split(',')
            .map(str::trim)
            .any(|candidate| candidate == selector);
        if listed {
            found = Some(match found {
                Some(previous) => format!("{previous}\n{body}"),
                None => body.to_string(),
            });
        }
    }
    found
}

/// Комментарии убираются до разбора: иначе комментарий перед правилом
/// приклеивается к первому селектору и правило перестаёт находиться.
fn strip_comments(css: &str) -> String {
    let mut out = String::with_capacity(css.len());
    let mut rest = css;
    while let Some(start) = rest.find("/*") {
        out.push_str(&rest[..start]);
        match rest[start..].find("*/") {
            Some(end) => rest = &rest[start + end + 2..],
            None => return out,
        }
    }
    out.push_str(rest);
    out
}
