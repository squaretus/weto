//! Запись журнала — порт `JournalRow` с macOS.
//!
//! Всё одним тестом: GTK поднимается на один поток, а `cargo test` раздаёт
//! тесты по разным, и второй `init` уже не получает главный контекст.

use gtk4::prelude::*;
use gtk4::Label;

use weto_ui::components as ui;

fn lines(row: &gtk4::Box) -> Vec<Label> {
    let mut lines = Vec::new();
    let mut child = row.first_child();
    while let Some(widget) = child {
        child = widget.next_sibling();
        lines.push(widget.downcast::<Label>().expect("в записи только строки"));
    }
    lines
}

/// Исход эпизода — своя строка цветом сводки, а не хвост блёклых показаний;
/// без исхода строки нет вовсе. Строки одной записи стоят с зазором 2,
/// а показания выделяются мышью.
#[test]
fn the_outcome_is_a_line_of_its_own() {
    gtk4::init().expect("GTK не поднялся: тестам нужен дисплей, запускать под Xvfb");

    let with_outcome = ui::journal_row(
        "claude · pid 42",
        "на паузе — подключение ещё не проверено",
        Some("Итог: возобновлено проверкой"),
        "06.10.2026 14:03:09 · IP: неизвестен",
    );
    let lines_with_outcome = lines(&with_outcome);
    let texts: Vec<String> = lines_with_outcome
        .iter()
        .map(|line| line.text().to_string())
        .collect();
    assert_eq!(
        texts,
        [
            "claude · pid 42",
            "на паузе — подключение ещё не проверено",
            "Итог: возобновлено проверкой",
            "06.10.2026 14:03:09 · IP: неизвестен",
        ]
    );
    assert!(lines_with_outcome[2].has_css_class("weto-value"));
    assert!(lines_with_outcome[3].has_css_class("weto-journal-diagnostics"));
    assert!(lines_with_outcome[3].is_selectable());
    assert_eq!(with_outcome.spacing(), 2);

    let without_outcome =
        ui::journal_row("claude · pid 42", "завершено — VPN не поднят", None, "t");
    assert_eq!(lines(&without_outcome).len(), 3);
}
