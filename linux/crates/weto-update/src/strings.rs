//! Тексты обновления — порт `UpdateStrings` из UpdateKitCore.
//!
//! Слова баннера и окна обязаны совпадать с macOS дословно, и решает, как
//! звучит каждая фаза, одно место. Перенесены тексты фаз; остальные тексты
//! окна переедут сюда вместе с самим окном.

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
                .unwrap_or_else(|| "Установка не удалась".to_string()),
            UpdatePhase::Idle => self.banner_available(version),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::progress::{UpdatePhase, UpdateProgress};

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
