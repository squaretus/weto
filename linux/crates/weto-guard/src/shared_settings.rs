//! Настройки приложения с окном, общие для охраны и интерфейса.
//!
//! Жили в GTK-крейте `weto-app`; перенесены без изменения поведения, потому
//! что их же держит мост Windows-версии (`windows/crates/weto-ffi`).

use std::sync::{Arc, Mutex};

use weto_config::paths::Paths;
use weto_config::settings::Settings;

use crate::controller::SettingsProviding;

/// Настройки читаются из файла при каждом обращении охраны — так правка
/// из окна настроек применяется к следующему же тику без всякой рассылки.
pub struct SharedSettings {
    path: std::path::PathBuf,
    cached: Mutex<Settings>,
}

impl SharedSettings {
    pub fn load(paths: &Paths) -> Arc<SharedSettings> {
        let path = paths.settings_file();
        let cached = Settings::load(&path).unwrap_or_default();
        Arc::new(SharedSettings {
            path,
            cached: Mutex::new(cached),
        })
    }

    pub fn current(&self) -> Settings {
        self.cached.lock().expect("настройки").clone()
    }

    /// Правка всегда поднимает ревизию: по ней охрана понимает, что прежний
    /// вердикт больше не свеж.
    pub fn edit(&self, change: impl FnOnce(&mut Settings)) {
        let mut settings = self.cached.lock().expect("настройки");
        change(&mut settings);
        settings.revision += 1;
        if let Err(error) = settings.save(&self.path) {
            eprintln!("weto: настройки не сохранились: {error}");
        }
    }

    /// Правка без ревизии — для того, что решения политики не меняет. Ревизия
    /// обесценивает вердикт, и смена потолка паузы уводила бы охрану
    /// в «Проверку» с пробой.
    pub fn edit_untracked(&self, change: impl FnOnce(&mut Settings)) {
        let mut settings = self.cached.lock().expect("настройки");
        change(&mut settings);
        if let Err(error) = settings.save(&self.path) {
            eprintln!("weto: настройки не сохранились: {error}");
        }
    }
}

/// Обёртка ради правила сирот: и трейт, и `Arc` объявлены не здесь,
/// поэтому реализовать одно для другого напрямую нельзя.
pub struct SettingsSource(pub Arc<SharedSettings>);

impl SettingsProviding for SettingsSource {
    fn settings(&self) -> Settings {
        self.0.current()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Потолок паузы правится мимо ревизии: ревизия обесценивает вердикт,
    /// и смена потолка уводила бы охрану в «Проверку» с пробой.
    #[test]
    fn an_untracked_edit_is_saved_but_does_not_bump_the_revision() {
        let home = std::env::temp_dir().join(format!(
            "weto-state-untracked-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let paths = weto_config::paths::Paths::rooted(home.clone());
        let settings = SharedSettings::load(&paths);
        let revision = settings.current().revision;

        settings.edit_untracked(|s| s.pause_ceiling_seconds = 600);

        assert_eq!(settings.current().revision, revision);
        assert_eq!(settings.current().pause_ceiling_seconds, 600);
        assert_eq!(
            Settings::load(&paths.settings_file())
                .unwrap()
                .pause_ceiling_seconds,
            600,
            "правка дошла до файла"
        );
        let _ = std::fs::remove_dir_all(home);
    }
}
