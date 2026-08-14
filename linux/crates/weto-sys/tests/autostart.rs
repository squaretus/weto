//! Автозапуск: один файл, честная ошибка, идемпотентность.

use weto_sys::autostart::Autostart;

/// Правило перенесено с macOS дословно. Там его нарушение дало пару
/// расходящихся заданий, которые перезапускали друг друга.
#[test]
fn autostart_lives_in_exactly_one_file() {
    let tmp = tempfile::tempdir().unwrap();
    let file = tmp.path().join("autostart/weto.desktop");
    let autostart = Autostart::rooted(file.clone());

    assert!(!autostart.is_enabled());
    autostart.enable().unwrap();

    let entries: Vec<_> = std::fs::read_dir(tmp.path().join("autostart"))
        .unwrap()
        .flatten()
        .collect();
    assert_eq!(entries.len(), 1);
    assert!(autostart.is_enabled());

    autostart.disable().unwrap();
    assert!(!autostart.is_enabled());
}

#[test]
fn enabling_twice_does_not_multiply_the_file() {
    let tmp = tempfile::tempdir().unwrap();
    let autostart = Autostart::rooted(tmp.path().join("autostart/weto.desktop"));

    autostart.enable().unwrap();
    autostart.enable().unwrap();

    let entries = std::fs::read_dir(tmp.path().join("autostart"))
        .unwrap()
        .count();
    assert_eq!(entries, 1);
}

#[test]
fn disabling_what_was_never_enabled_is_not_an_error() {
    let tmp = tempfile::tempdir().unwrap();
    let autostart = Autostart::rooted(tmp.path().join("autostart/weto.desktop"));

    assert!(autostart.disable().is_ok());
}

/// Тихая ошибка выдавала бы автозапуск за включённый, и пользователь узнал бы
/// правду только после перезагрузки — с незапущенной охраной.
#[test]
fn a_failed_write_is_reported_not_swallowed() {
    let autostart = Autostart::rooted("/proc/недоступно/weto.desktop".into());

    assert!(autostart.enable().is_err());
}

/// Ярлык обязан указывать на исполняемый файл абсолютным путём: сессия
/// стартует без `$PATH` пользователя.
#[test]
fn the_entry_points_at_an_absolute_executable() {
    let tmp = tempfile::tempdir().unwrap();
    let file = tmp.path().join("autostart/weto.desktop");
    Autostart::rooted(file.clone()).enable().unwrap();

    let text = std::fs::read_to_string(&file).unwrap();
    let exec = text
        .lines()
        .find_map(|line| line.strip_prefix("Exec="))
        .expect("в ярлыке есть Exec");

    assert!(exec.starts_with('/'), "Exec={exec}");
    assert!(text.contains("Type=Application"));
}
