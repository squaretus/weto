//! Что именно показывает окно обновления — порт `UpdateDialogModel` с macOS.
//!
//! Отдельный тип, потому что вёрстка не должна решать, когда прятать кнопки:
//! это правило, а не оформление, и проверяется оно синхронным тестом без GTK.

use crate::policy::UpdateInfo;
use crate::progress::{UpdatePhase, UpdateProgress};
use crate::strings::UpdateStrings;

#[derive(Debug, Clone, PartialEq)]
pub struct UpdateDialogModel {
    pub title: String,
    pub detail: String,
    /// `None` — полоса неопределённая либо её нет вовсе.
    pub fraction: Option<f64>,
    /// Полоса хода видна: идёт проверка, загрузка или установка. На macOS
    /// это решает вёрстка по `progress.isInFlight`; здесь — модель, чтобы
    /// окно не спрашивало ход дважды.
    pub shows_progress: bool,
    /// Ряд «Пропустить / Напомнить позже / Обновить» и галочка автоустановки.
    pub shows_choice_buttons: bool,
    pub shows_release_page_button: bool,
}

impl UpdateDialogModel {
    /// Случая «в релизе нет пакета» здесь нет, в отличие от macOS: релиз
    /// без архива под Linux `ReleaseChecker` находкой не считает, и окно
    /// о нём не открывается вовсе.
    pub fn make(
        info: Option<&UpdateInfo>,
        progress: &UpdateProgress,
        strings: &UpdateStrings,
    ) -> UpdateDialogModel {
        let Some(info) = info else {
            return progress_model(strings, strings.checking().to_string(), None);
        };

        match progress.phase {
            UpdatePhase::Idle => UpdateDialogModel {
                title: strings.offer_title(),
                detail: strings.offer_detail(&info.latest_version, &info.current_version),
                fraction: None,
                shows_progress: false,
                shows_choice_buttons: true,
                shows_release_page_button: false,
            },
            UpdatePhase::Checking => progress_model(strings, strings.checking().to_string(), None),
            UpdatePhase::Downloading => progress_model(
                strings,
                strings.downloading(&info.latest_version),
                Some(progress.fraction),
            ),
            UpdatePhase::Installing => {
                progress_model(strings, strings.installing().to_string(), None)
            }
            UpdatePhase::Failed => UpdateDialogModel {
                title: strings.progress_title(),
                detail: progress
                    .failure
                    .clone()
                    .unwrap_or_else(|| strings.failed().to_string()),
                fraction: None,
                shows_progress: false,
                shows_choice_buttons: false,
                // Отказ не оставляет окно без единой кнопки: ручной путь есть всегда.
                shows_release_page_button: true,
            },
        }
    }
}

fn progress_model(
    strings: &UpdateStrings,
    detail: String,
    fraction: Option<f64>,
) -> UpdateDialogModel {
    UpdateDialogModel {
        title: strings.progress_title(),
        detail,
        fraction,
        shows_progress: true,
        shows_choice_buttons: false,
        shows_release_page_button: false,
    }
}

/// Страница релиза, которую можно открыть. Адрес приходит из сети, поэтому
/// открывается только https на github.com — как `validatedReleaseURL` на macOS.
/// Без находки — общая страница релизов.
pub fn release_page(info: Option<&UpdateInfo>, fallback: &str) -> Option<String> {
    let address = info.map_or(fallback, |info| info.release_url.as_str());
    is_github_page(address).then(|| address.to_string())
}

/// Хост сверяется целиком, а не префиксом: `https://github.com@evil.example/`
/// начинается с нужных букв, но ведёт на чужой хост.
fn is_github_page(address: &str) -> bool {
    let Some(rest) = address.strip_prefix("https://") else {
        return false;
    };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    authority == "github.com"
}
