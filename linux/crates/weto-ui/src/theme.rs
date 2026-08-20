//! Установка темы приложения.
//!
//! Тема выбирается явно и системной не следует — так написано в каноне,
//! и именно поэтому libadwaita не годится: он навязывает системную палитру
//! и сопротивляется её подмене. Голый GTK4 такого мнения не имеет.

use gtk4::prelude::*;
use gtk4::{gdk, CssProvider};

pub use weto_core::presentation::ShieldState;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Theme {
    Dark,
    Light,
}

impl Theme {
    pub fn css_class(self) -> &'static str {
        match self {
            Theme::Dark => "theme-dark",
            Theme::Light => "theme-light",
        }
    }
}

/// Готовые таблицы стилей, по одной на тему, вкомпилированные в бинарник.
///
/// Файлами на диске они быть не могут: приложение ставится подменой каталога,
/// и стили обязаны меняться вместе с исполняемым файлом, а не отдельно от него.
///
/// Две таблицы, а не одна с переменными: `var()` появился в GTK 4.16, а пол
/// проекта — 4.14. Значения подставлены генератором при сборке.
pub const DARK_CSS: &str = include_str!("../style/theme-dark.css");
pub const LIGHT_CSS: &str = include_str!("../style/theme-light.css");

pub fn css_for(theme: Theme) -> &'static str {
    match theme {
        Theme::Dark => DARK_CSS,
        Theme::Light => LIGHT_CSS,
    }
}

/// Ставит стили выбранной темы на дисплей с приоритетом APPLICATION.
///
/// Приоритет важен: ниже пользовательской темы, но выше умолчаний GTK,
/// так что чужая тема не переписывает наши цвета, а системные виджеты
/// не остаются в дефолтном виде.
///
/// Возвращает провайдер: смена темы — это подмена таблицы, а не переключение
/// класса, и старый провайдер нужно уметь снять.
pub fn install_styles(theme: Theme) -> CssProvider {
    let provider = CssProvider::new();
    provider.load_from_string(css_for(theme));

    if let Some(display) = gdk::Display::default() {
        gtk4::style_context_add_provider_for_display(
            &display,
            &provider,
            gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }
    provider
}

/// Снимает прежнюю таблицу и ставит новую.
pub fn switch_theme(previous: &CssProvider, theme: Theme) -> CssProvider {
    if let Some(display) = gdk::Display::default() {
        gtk4::style_context_remove_provider_for_display(&display, previous);
    }
    install_styles(theme)
}

/// Помечает корневой виджет: базовый шрифт и цвет текста висят на этом классе.
pub fn mark_root(root: &impl IsA<gtk4::Widget>) {
    root.as_ref().add_css_class("weto-root");
}

/// Класс состояния для щита и заголовка статуса.
pub fn shield_class(state: ShieldState) -> &'static str {
    match state {
        ShieldState::Guarded => "guarded",
        ShieldState::Degraded => "pending",
        ShieldState::Pending => "pending",
        ShieldState::Killed => "killed",
        ShieldState::Disabled => "disabled",
    }
}
