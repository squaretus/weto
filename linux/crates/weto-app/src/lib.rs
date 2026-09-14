//! Библиотечная часть weto-app.
//!
//! Здесь живёт всё, кроме точки входа: окна, состояние, обновление и трей.
//! Не из любви к раскладке — из-за проверок. Окно настроек умеет утекать
//! целиком, и поймать это можно только на настоящем окне, построенном тем же
//! кодом, что и в продукте. Из бинарной цели его не достать, а второй
//! GTK-тест в одном процессе падает на «Attempted to initialize GTK from two
//! different threads», — поэтому окна строит библиотека, а каждый GTK-тест
//! живёт своим файлом и своим процессом.

use std::cell::RefCell;

use gtk4::CssProvider;
use weto_config::settings::Theme as SettingsTheme;
use weto_ui::theme::{self, Theme};

pub mod lifecycle;
pub mod settings_window;
pub mod state;
pub mod status_window;
pub mod tray;
pub mod uninstall;
pub mod update;
pub mod update_window;

thread_local! {
    static STYLES: RefCell<Option<CssProvider>> = const { RefCell::new(None) };
}

/// Смена темы — подмена таблицы стилей целиком: CSS-переменных на GTK 4.14 нет,
/// поэтому цвета вкомпилированы в две отдельные таблицы.
pub fn apply_theme(theme: SettingsTheme) {
    let theme = match theme {
        SettingsTheme::Dark => Theme::Dark,
        SettingsTheme::Light => Theme::Light,
    };
    STYLES.with(|slot| {
        let mut slot = slot.borrow_mut();
        let provider = match slot.as_ref() {
            Some(previous) => theme::switch_theme(previous, theme),
            None => theme::install_styles(theme),
        };
        *slot = Some(provider);
    });
}
