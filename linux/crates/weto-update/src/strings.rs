//! Тексты обновления — порт `UpdateStrings` из UpdateKitCore.
//!
//! Слова баннера и окна обязаны совпадать с macOS дословно, и решает, как
//! звучит каждая фаза, одно место. Не перенесены только тексты про демон
//! и релиз без пакета: демона на Linux нет, а релиз без архива под Linux
//! находкой не считается вовсе (`ReleaseChecker::latest`).

use crate::policy::RemindInterval;
use crate::progress::{UpdatePhase, UpdateProgress};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UpdateStrings {
    pub app_name: String,
}

impl UpdateStrings {
    pub fn new(app_name: &str) -> UpdateStrings {
        UpdateStrings {
            app_name: app_name.to_string(),
        }
    }

    pub fn offer_title(&self) -> String {
        format!("Доступна новая версия {}", self.app_name)
    }

    pub fn offer_detail(&self, latest: &str, current: &str) -> String {
        format!(
            "{} {latest} — у вас {current}. Обновиться сейчас?",
            self.app_name
        )
    }

    pub fn progress_title(&self) -> String {
        format!("Обновление {}", self.app_name)
    }

    pub fn auto_install_toggle(&self) -> &'static str {
        "Обновлять автоматически в дальнейшем"
    }

    pub fn skip(&self) -> &'static str {
        "Пропустить версию"
    }

    pub fn remind_later(&self) -> &'static str {
        "Напомнить позже"
    }

    pub fn install(&self) -> &'static str {
        "Обновить"
    }

    pub fn open_release_page(&self) -> &'static str {
        "Открыть страницу релиза"
    }

    pub fn remind_title(&self, interval: RemindInterval) -> &'static str {
        match interval {
            RemindInterval::OneHour => "через час",
            RemindInterval::ThreeHours => "через 3 часа",
            RemindInterval::SixHours => "через 6 часов",
        }
    }

    /// Отказ без объяснения. На macOS здесь «связь со службой потеряна»,
    /// но службы на Linux нет — говорим то же, что баннер.
    pub fn failed(&self) -> &'static str {
        "Установка не удалась"
    }

    pub fn downloading(&self, version: &str) -> String {
        format!("Загрузка {version}…")
    }

    pub fn checking(&self) -> &'static str {
        "Проверка релиза…"
    }

    pub fn installing(&self) -> &'static str {
        "Установка…"
    }

    pub fn banner_available(&self, version: &str) -> String {
        format!("Доступно обновление {version}")
    }

    /// Баннер в попапе показывает те же фазы, что и окно.
    pub fn banner_progress(&self, progress: &UpdateProgress, version: &str) -> String {
        match progress.phase {
            UpdatePhase::Checking => self.checking().to_string(),
            // Отбрасывание дробной части, а не округление: как `Int(…)` на macOS,
            // «100 %» не появляется раньше конца загрузки.
            UpdatePhase::Downloading => format!(
                "{} {} %",
                self.downloading(version),
                (progress.fraction * 100.0) as i32
            ),
            UpdatePhase::Installing => self.installing().to_string(),
            UpdatePhase::Failed => progress
                .failure
                .clone()
                .unwrap_or_else(|| self.failed().to_string()),
            UpdatePhase::Idle => self.banner_available(version),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::progress::{UpdatePhase, UpdateProgress};

    /// Окно обновления говорит словами `UpdateStrings` с macOS — дословно,
    /// вместе с регистром: «Пропустить версию», а не «Пропустить эту версию».
    #[test]
    fn the_window_speaks_like_macos() {
        use crate::policy::RemindInterval;

        let strings = UpdateStrings::new("Weto");

        assert_eq!(strings.offer_title(), "Доступна новая версия Weto");
        assert_eq!(
            strings.offer_detail("0.5.0", "0.4.0"),
            "Weto 0.5.0 — у вас 0.4.0. Обновиться сейчас?"
        );
        assert_eq!(strings.progress_title(), "Обновление Weto");
        assert_eq!(strings.downloading("0.5.0"), "Загрузка 0.5.0…");
        assert_eq!(strings.installing(), "Установка…");
        assert_eq!(
            strings.auto_install_toggle(),
            "Обновлять автоматически в дальнейшем"
        );
        assert_eq!(strings.skip(), "Пропустить версию");
        assert_eq!(strings.remind_later(), "Напомнить позже");
        assert_eq!(strings.install(), "Обновить");
        assert_eq!(strings.open_release_page(), "Открыть страницу релиза");
        assert_eq!(
            RemindInterval::ALL.map(|interval| strings.remind_title(interval)),
            ["через час", "через 3 часа", "через 6 часов"]
        );
    }

    /// Баннер в попапе говорит теми же словами, что `UpdateStrings.bannerProgress`
    /// на macOS, — дословно.
    #[test]
    fn the_banner_names_each_phase_like_macos() {
        let strings = UpdateStrings::new("Weto");
        let say = |progress: UpdateProgress| strings.banner_progress(&progress, "0.4.0");

        assert_eq!(say(UpdateProgress::idle()), "Доступно обновление 0.4.0");
        assert_eq!(
            say(UpdateProgress::new(UpdatePhase::Checking, 0.0, None)),
            "Проверка релиза…"
        );
        assert_eq!(
            say(UpdateProgress::new(UpdatePhase::Downloading, 0.427, None)),
            "Загрузка 0.4.0… 42 %"
        );
        assert_eq!(
            say(UpdateProgress::new(UpdatePhase::Installing, 1.0, None)),
            "Установка…"
        );
        assert_eq!(
            say(UpdateProgress::new(
                UpdatePhase::Failed,
                0.0,
                Some("скачивание не удалось: нет сети".into())
            )),
            "скачивание не удалось: нет сети"
        );
        assert_eq!(
            say(UpdateProgress::new(UpdatePhase::Failed, 0.0, None)),
            "Установка не удалась"
        );
    }
}
