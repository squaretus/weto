//! Что пользователь сказал о показе обновлений и что переживает перезапуск.
//!
//! Отсрочка хранится абсолютной датой, а не «через час»: относительный срок
//! после перезапуска начинался бы заново, и окно всплывало бы на каждом старте.

use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::policy::UpdateDeferral;

#[derive(Debug, Default, Serialize, Deserialize)]
struct Stored {
    #[serde(default)]
    skipped_version: Option<String>,
    /// Секунды эпохи. Так же, как в общих фикстурах, — чтобы значение
    /// читалось глазами и не зависело от формата дат.
    #[serde(default)]
    remind_at: Option<u64>,
    #[serde(default)]
    auto_install: bool,
}

pub struct UpdateStore {
    path: PathBuf,
}

impl UpdateStore {
    pub fn new(state_dir: PathBuf) -> UpdateStore {
        UpdateStore {
            path: state_dir.join("update.json"),
        }
    }

    /// Испорченный файл читается как «ничего не откладывали»: это состояние
    /// диалога, а не данные пользователя, и терять его безопаснее, чем
    /// молчать об обновлениях из-за нечитаемой строки.
    fn stored(&self) -> Stored {
        std::fs::read_to_string(&self.path)
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default()
    }

    fn save(&self, stored: &Stored) {
        if let Some(parent) = self.path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(text) = serde_json::to_string_pretty(stored) {
            let _ = std::fs::write(&self.path, text);
        }
    }

    pub fn deferral(&self) -> UpdateDeferral {
        let stored = self.stored();
        UpdateDeferral {
            skipped_version: stored.skipped_version,
            remind_at: stored
                .remind_at
                .map(|s| UNIX_EPOCH + Duration::from_secs(s)),
            auto_install: stored.auto_install,
        }
    }

    /// Пропуск действует ровно до выхода версии выше — отдельного способа
    /// снять его не требуется, и в настройках его нет.
    pub fn skip(&self, version: &str) {
        let mut stored = self.stored();
        stored.skipped_version = Some(version.to_string());
        self.save(&stored);
    }

    pub fn remind_later(&self, after: Duration) {
        let mut stored = self.stored();
        stored.remind_at = SystemTime::now()
            .checked_add(after)
            .and_then(|at| at.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_secs());
        self.save(&stored);
    }

    pub fn set_auto_install(&self, enabled: bool) {
        let mut stored = self.stored();
        stored.auto_install = enabled;
        self.save(&stored);
    }

    /// После успешной установки прежние отсрочки бессмысленны: они относились
    /// к версии, которая уже стоит.
    pub fn clear(&self) {
        self.save(&Stored::default());
    }
}
