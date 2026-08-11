//! Настройки: то, что пользователь задал, и ничего больше.

use std::path::Path;

use serde::{Deserialize, Serialize};
use weto_core::ip::IpRange;
use weto_core::policy::GuardConfig;
use weto_core::process::{TargetKind, TargetRule};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub is_enabled: bool,
    /// Имя интерфейса. `None` — VPN не выбран, и это отдельная причина
    /// завершения, а не «любой сойдёт».
    pub vpn_interface: Option<String>,
    pub blocked_countries: Vec<String>,
    pub blocked_ip_ranges: Vec<String>,
    pub targets: Vec<Target>,
    pub theme: Theme,
    pub notify_on_kill: bool,
    /// Ревизия растёт на каждое сохранение: по ней охрана понимает, что прежний
    /// вердикт больше не свеж.
    pub revision: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Theme {
    #[default]
    Dark,
    Light,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Target {
    /// То, что ввёл пользователь.
    pub entry: String,
    pub display_name: String,
    pub kind: TargetKind,
    /// Путь после разворота симлинков.
    pub path: String,
    #[serde(default)]
    pub launch_paths: Vec<String>,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            is_enabled: true,
            vpn_interface: None,
            blocked_countries: Vec::new(),
            blocked_ip_ranges: Vec::new(),
            targets: Vec::new(),
            theme: Theme::Dark,
            notify_on_kill: true,
            revision: 0,
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum SettingsError {
    #[error("не прочитать настройки: {0}")]
    Read(String),
    #[error("не записать настройки: {0}")]
    Write(String),
    #[error("настройки испорчены: {0}")]
    Parse(String),
}

impl Settings {
    /// Отсутствие файла — не ошибка: свежая установка начинает с умолчаний.
    pub fn load(path: &Path) -> Result<Settings, SettingsError> {
        match std::fs::read_to_string(path) {
            Ok(text) => toml::from_str(&text).map_err(|e| SettingsError::Parse(e.to_string())),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Settings::default()),
            Err(error) => Err(SettingsError::Read(error.to_string())),
        }
    }

    /// Запись через временный файл и переименование: прерванная запись
    /// не оставит половину настроек вместо целых.
    pub fn save(&self, path: &Path) -> Result<(), SettingsError> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| SettingsError::Write(e.to_string()))?;
        }

        let text = toml::to_string_pretty(self).map_err(|e| SettingsError::Write(e.to_string()))?;
        let temporary = path.with_extension("toml.tmp");

        std::fs::write(&temporary, text).map_err(|e| SettingsError::Write(e.to_string()))?;
        std::fs::rename(&temporary, path).map_err(|e| SettingsError::Write(e.to_string()))
    }

    /// Правила целей для матчера. Неразбираемые диапазоны отбрасываются молча:
    /// в настройках они уже проверены при вводе, а падать из-за правки файла
    /// руками охрана не должна — она должна продолжать охранять.
    pub fn guard_config(&self) -> GuardConfig {
        GuardConfig {
            vpn_id: self.vpn_interface.clone(),
            blocked_countries: self.blocked_countries.iter().cloned().collect(),
            blocked_ip_ranges: self
                .blocked_ip_ranges
                .iter()
                .filter_map(|text| IpRange::parse(text))
                .collect(),
            targets: self.targets.iter().map(|t| t.entry.clone()).collect(),
        }
    }

    pub fn target_rules(&self) -> Vec<TargetRule> {
        self.targets
            .iter()
            .map(|target| TargetRule {
                entry: target.entry.clone(),
                display_name: target.display_name.clone(),
                kind: target.kind,
                path: target.path.clone(),
                launch_paths: {
                    let mut paths = vec![target.path.clone()];
                    for extra in &target.launch_paths {
                        if !paths.contains(extra) {
                            paths.push(extra.clone());
                        }
                    }
                    paths
                },
            })
            .collect()
    }
}
