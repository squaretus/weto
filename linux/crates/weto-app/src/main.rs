//! Точка входа Linux-версии weto.
//!
//! Приложение единственное в системе: повторный запуск не поднимает второй
//! процесс, а показывает окно уже работающей копии. Это второй вход помимо
//! трея — он обязателен, потому что окружение может быть без трея вовсе
//! (ванильный GNOME без расширений).

mod settings_window;
mod state;
mod status_window;
mod tray;
mod update;
mod update_window;

use std::cell::RefCell;

use gtk4::gio::ApplicationFlags;
use gtk4::prelude::*;
use gtk4::{Application, CssProvider};

use weto_config::paths::Paths;
use weto_config::settings::Theme as SettingsTheme;
use weto_ui::theme::{self, Theme};

const APP_ID: &str = "com.weto.app";

thread_local! {
    static STYLES: RefCell<Option<CssProvider>> = const { RefCell::new(None) };
    static TRAY_UP: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
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

fn main() -> gtk4::glib::ExitCode {
    // Флаги командной строки обслуживаются до GTK: контракту установки нужен
    // ответ без дисплея, а --autostart вообще не про интерфейс.
    let arguments: Vec<String> = std::env::args().collect();
    if let Some(code) = handle_cli(&arguments) {
        return code;
    }

    let paths = Paths::from_env();
    let state = state::AppState::new(paths);

    // Раньше всего остального: если предыдущий запуск не дожил до окна дважды
    // подряд, новая версия не стартует — возвращаемся к прежней и уходим в неё.
    update::guard_the_launch(&state);

    let application = Application::builder()
        .application_id(APP_ID)
        .flags(ApplicationFlags::empty())
        .build();

    {
        let state = state.clone();
        application.connect_startup(move |_| {
            apply_theme(state.theme());
            // Охрана стартует здесь, а не при первом открытии окна: окно
            // может не открыться никогда, а защита нужна с первой секунды.
            state.start_guard();
            update::start(state.clone());
        });
    }

    {
        let state = state.clone();
        application.connect_activate(move |app| {
            // Трей поднимается один раз, при первой активации: раньше главного
            // цикла подписываться не на что.
            if !TRAY_UP.with(|up| up.replace(true)) {
                tray::install(app, state.clone());
            }
            match app.active_window() {
                Some(window) => window.present(),
                None => status_window::build(app, state.clone()).present(),
            }
        });
    }

    application.run_with_args::<&str>(&[])
}

fn handle_cli(arguments: &[String]) -> Option<gtk4::glib::ExitCode> {
    match arguments.get(1).map(String::as_str) {
        Some("--version") => {
            // Версия приходит из окружения сборки: релизный скрипт не правит
            // отслеживаемые файлы, поэтому в Cargo.toml она остаётся нулевой.
            println!(
                "{}",
                option_env!("WETO_VERSION").unwrap_or(env!("CARGO_PKG_VERSION"))
            );
            Some(gtk4::glib::ExitCode::SUCCESS)
        }
        Some("--autostart") => {
            let paths = Paths::from_env();
            let result = match arguments.get(2).map(String::as_str) {
                Some("on") => weto_sys::autostart::Autostart::new(&paths).enable(),
                Some("off") => weto_sys::autostart::Autostart::new(&paths).disable(),
                _ => {
                    eprintln!("использование: weto --autostart on|off");
                    return Some(gtk4::glib::ExitCode::FAILURE);
                }
            };
            match result {
                Ok(()) => Some(gtk4::glib::ExitCode::SUCCESS),
                Err(error) => {
                    eprintln!("weto: {error}");
                    Some(gtk4::glib::ExitCode::FAILURE)
                }
            }
        }
        _ => None,
    }
}
