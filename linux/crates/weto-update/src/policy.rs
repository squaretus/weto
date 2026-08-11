//! Что делать с найденным обновлением.
//!
//! Чистая функция и единственное место, принимающее это решение: и приложение,
//! и тесты получают один и тот же ответ. Порт `UpdatePolicy` с macOS, сверяется
//! общими фикстурами.

use std::time::{Duration, SystemTime};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// Ни окна, ни баннера: версия пропущена, отложена или не новее текущей.
    Silent,
    Prompt,
    Install,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UpdateInfo {
    pub latest_version: String,
    pub download_url: String,
    pub release_notes: Option<String>,
    pub is_newer: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct UpdateDeferral {
    /// Версия, о которой просили больше не напоминать. Действует ровно
    /// до выхода версии выше — отдельного способа снять пропуск не требуется.
    pub skipped_version: Option<String>,
    /// Абсолютная дата, раньше которой окно не всплывает.
    pub remind_at: Option<SystemTime>,
    pub auto_install: bool,
}

/// Дальше этого срока сохранённое напоминание считается испорченным: перевод
/// системных часов назад иначе запер бы обновления надолго.
pub const MAXIMUM_REMIND_INTERVAL: Duration = Duration::from_secs(6 * 3600);

pub fn decide(latest: &UpdateInfo, deferral: &UpdateDeferral, now: SystemTime) -> Outcome {
    if !latest.is_newer {
        return Outcome::Silent;
    }
    if deferral.auto_install {
        return Outcome::Install;
    }
    if deferral.skipped_version.as_deref() == Some(latest.latest_version.as_str()) {
        return Outcome::Silent;
    }
    if let Some(remind_at) = deferral.remind_at {
        let in_future = remind_at > now;
        let within_sanity = remind_at
            <= now
                .checked_add(MAXIMUM_REMIND_INTERVAL)
                .unwrap_or(remind_at);
        if in_future && within_sanity {
            return Outcome::Silent;
        }
    }
    Outcome::Prompt
}
