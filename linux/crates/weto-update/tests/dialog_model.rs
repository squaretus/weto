//! Что показывает окно обновления — порт `UpdateDialogModelTests` с macOS.
//!
//! Когда прятать кнопки — правило, а не оформление, и проверяется оно здесь,
//! синхронно и без GTK.

use weto_update::dialog::{release_page, UpdateDialogModel};
use weto_update::policy::UpdateInfo;
use weto_update::progress::{UpdatePhase, UpdateProgress};
use weto_update::strings::UpdateStrings;

fn strings() -> UpdateStrings {
    UpdateStrings::new("Sample")
}

fn info() -> UpdateInfo {
    UpdateInfo {
        current_version: "0.4.0".to_string(),
        latest_version: "0.4.2".to_string(),
        release_url: "https://github.com/example/sample/releases/tag/v0.4.2".to_string(),
        download_url:
            "https://github.com/example/sample/releases/download/v0.4.2/sample-0.4.2-x86_64-linux.tar.zst"
                .to_string(),
        is_newer: true,
    }
}

#[test]
fn the_offer_names_both_versions() {
    let model = UpdateDialogModel::make(Some(&info()), &UpdateProgress::idle(), &strings());

    assert_eq!(model.title, "Доступна новая версия Sample");
    assert_eq!(
        model.detail,
        "Sample 0.4.2 — у вас 0.4.0. Обновиться сейчас?"
    );
    assert!(model.shows_choice_buttons);
    assert_eq!(model.fraction, None);
    assert!(!model.shows_release_page_button);
    assert!(!model.shows_progress);
}

#[test]
fn downloading_shows_a_real_fraction() {
    let model = UpdateDialogModel::make(
        Some(&info()),
        &UpdateProgress::new(UpdatePhase::Downloading, 0.62, None),
        &strings(),
    );

    assert_eq!(model.title, "Обновление Sample");
    assert_eq!(model.detail, "Загрузка 0.4.2…");
    assert!((model.fraction.unwrap_or(0.0) - 0.62).abs() < 0.0001);
    assert!(model.shows_progress);
    assert!(!model.shows_choice_buttons);
}

#[test]
fn installing_is_indeterminate() {
    let model = UpdateDialogModel::make(
        Some(&info()),
        &UpdateProgress::new(UpdatePhase::Installing, 1.0, None),
        &strings(),
    );

    assert_eq!(model.detail, "Установка…");
    assert_eq!(
        model.fraction, None,
        "распаковка хода не отдаёт — полосу не подделываем"
    );
    assert!(model.shows_progress);
}

#[test]
fn checking_is_indeterminate_and_offers_nothing() {
    let model = UpdateDialogModel::make(
        Some(&info()),
        &UpdateProgress::new(UpdatePhase::Checking, 0.0, None),
        &strings(),
    );

    assert_eq!(model.title, "Обновление Sample");
    assert_eq!(model.detail, "Проверка релиза…");
    assert_eq!(model.fraction, None);
    assert!(!model.shows_choice_buttons);
    assert!(!model.shows_release_page_button);
}

#[test]
fn without_a_finding_the_window_says_it_is_checking() {
    let model = UpdateDialogModel::make(None, &UpdateProgress::idle(), &strings());

    assert_eq!(model.title, "Обновление Sample");
    assert_eq!(model.detail, "Проверка релиза…");
    assert!(!model.shows_choice_buttons);
    assert!(!model.shows_release_page_button);
}

/// Отказ не оставляет окно без единой кнопки: ручной путь — страница релиза.
#[test]
fn a_failure_offers_the_release_page() {
    let model = UpdateDialogModel::make(
        Some(&info()),
        &UpdateProgress::new(
            UpdatePhase::Failed,
            0.0,
            Some("скачивание не удалось: нет сети".into()),
        ),
        &strings(),
    );

    assert_eq!(model.title, "Обновление Sample");
    assert_eq!(model.detail, "скачивание не удалось: нет сети");
    assert!(model.shows_release_page_button);
    assert!(!model.shows_choice_buttons);
    assert!(!model.shows_progress);
}

#[test]
fn a_silent_failure_still_says_something() {
    let model = UpdateDialogModel::make(
        Some(&info()),
        &UpdateProgress::new(UpdatePhase::Failed, 0.0, None),
        &strings(),
    );

    assert_eq!(model.detail, "Установка не удалась");
}

/// Адрес страницы приходит из сети: открываем только https на github.com,
/// как `validatedReleaseURL` на macOS.
#[test]
fn only_a_github_https_page_is_opened() {
    let fallback = "https://github.com/squaretus/weto/releases";

    assert_eq!(
        release_page(Some(&info()), fallback).as_deref(),
        Some("https://github.com/example/sample/releases/tag/v0.4.2")
    );
    assert_eq!(release_page(None, fallback).as_deref(), Some(fallback));

    for forged in [
        "http://github.com/x/y",
        "https://github.com.evil.example/x",
        "https://github.com@evil.example/x",
        "https://evil.example/github.com",
        "javascript:alert(1)",
    ] {
        let mut info = info();
        info.release_url = forged.to_string();
        assert_eq!(
            release_page(Some(&info), fallback),
            None,
            "открылся {forged}"
        );
    }
}
