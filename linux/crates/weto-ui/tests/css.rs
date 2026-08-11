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
