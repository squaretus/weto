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
    /// Выбранное VPN-приложение — такая же цель по форме. `None` — не выбрано,
    /// и это отдельная причина завершения, а не «любое сойдёт».
    pub vpn_app: Option<Target>,
    pub blocked_countries: Vec<String>,
    pub blocked_ip_ranges: Vec<String>,
    /// Пустой whitelist — нормальное умолчание: он не сужает ничего.
    /// `serde(default)` держит обратную совместимость конфигов без этих ключей.
    #[serde(default)]
    pub allowed_countries: Vec<String>,
    #[serde(default)]
    pub allowed_ip_ranges: Vec<String>,
    pub targets: Vec<Target>,
    pub theme: Theme,
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
            vpn_app: None,
            blocked_countries: Vec::new(),
            blocked_ip_ranges: Vec::new(),
            allowed_countries: Vec::new(),
            allowed_ip_ranges: Vec::new(),
            targets: Vec::new(),
            theme: Theme::Dark,
            revision: 0,
        }
    }
}

/// Вид списка геоправил. Разбор записи, проверка дубликата и удаление —
/// один путь на оба списка: два экземпляра одного алгоритма разъезжались бы
/// молча, а расходиться им нельзя.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GeoListKind {
    Blocked,
    Allowed,
}

/// Отказы при вводе записи списка геоправил. Тексты — те же, что на macOS.
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum GeoListEntryError {
    #[error("введите код страны, IP-адрес или диапазон")]
    Empty,
    #[error("не похоже ни на код страны, ни на IP-адрес или CIDR")]
    InvalidEntry,
    #[error("такая запись уже есть в списке")]
    Duplicate,
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

    /// Записи одним списком — так их и показывает экран: пользователь ввёл
    /// одно поле, и разделение на страны и диапазоны его не касается.
    pub fn entries(&self, kind: GeoListKind) -> Vec<String> {
        let (countries, ranges) = self.lists(kind);
        let mut entries = countries.clone();
        entries.extend(ranges.iter().cloned());
        entries
    }

    /// Разбор живёт здесь, а не в окне: иначе мусорная запись молча попадала бы
    /// в настройки и висела там как «не разобрана».
    ///
    /// Путь один на оба списка — различает их только `kind`.
    pub fn add_entry(&mut self, text: &str, kind: GeoListKind) -> Result<(), GeoListEntryError> {
        let entry = text.trim();
        if entry.is_empty() {
            return Err(GeoListEntryError::Empty);
        }

        if entry.chars().count() == 2 && entry.chars().all(|c| c.is_alphabetic()) {
            let code = entry.to_uppercase();
            let (countries, _) = self.lists_mut(kind);
            if countries.contains(&code) {
                return Err(GeoListEntryError::Duplicate);
            }
            countries.push(code);
            return Ok(());
        }

        let Some(range) = IpRange::parse(entry) else {
            return Err(GeoListEntryError::InvalidEntry);
        };
        let (_, ranges) = self.lists_mut(kind);
        if ranges.contains(&range.text) {
            return Err(GeoListEntryError::Duplicate);
        }
        ranges.push(range.text);
        Ok(())
    }

    pub fn remove_entry(&mut self, entry: &str, kind: GeoListKind) {
        let (countries, ranges) = self.lists_mut(kind);
        countries.retain(|c| c != entry);
        ranges.retain(|r| r != entry);
    }

    fn lists(&self, kind: GeoListKind) -> (&Vec<String>, &Vec<String>) {
        match kind {
            GeoListKind::Blocked => (&self.blocked_countries, &self.blocked_ip_ranges),
            GeoListKind::Allowed => (&self.allowed_countries, &self.allowed_ip_ranges),
        }
    }

    fn lists_mut(&mut self, kind: GeoListKind) -> (&mut Vec<String>, &mut Vec<String>) {
        match kind {
            GeoListKind::Blocked => (&mut self.blocked_countries, &mut self.blocked_ip_ranges),
            GeoListKind::Allowed => (&mut self.allowed_countries, &mut self.allowed_ip_ranges),
        }
    }

    // Обёртки для вызовов из окна: ничего, кроме делегирования в общий путь.

    pub fn blocked_entries(&self) -> Vec<String> {
        self.entries(GeoListKind::Blocked)
    }

    pub fn add_blocked_entry(&mut self, text: &str) -> Result<(), GeoListEntryError> {
        self.add_entry(text, GeoListKind::Blocked)
    }

    pub fn remove_blocked_entry(&mut self, entry: &str) {
        self.remove_entry(entry, GeoListKind::Blocked)
    }

    pub fn allowed_entries(&self) -> Vec<String> {
        self.entries(GeoListKind::Allowed)
    }

    pub fn add_allowed_entry(&mut self, text: &str) -> Result<(), GeoListEntryError> {
        self.add_entry(text, GeoListKind::Allowed)
    }

    pub fn remove_allowed_entry(&mut self, entry: &str) {
        self.remove_entry(entry, GeoListKind::Allowed)
    }

    /// Правила целей для матчера. Неразбираемые диапазоны отбрасываются молча:
    /// в настройках они уже проверены при вводе, а падать из-за правки файла
    /// руками охрана не должна — она должна продолжать охранять.
    pub fn guard_config(&self) -> GuardConfig {
        GuardConfig {
            vpn_app: self.vpn_app.as_ref().map(|app| app.entry.clone()),
            blocked_countries: self.blocked_countries.iter().cloned().collect(),
            blocked_ip_ranges: self
                .blocked_ip_ranges
                .iter()
                .filter_map(|text| IpRange::parse(text))
                .collect(),
            allowed_countries: self.allowed_countries.iter().cloned().collect(),
            allowed_ip_ranges: self
                .allowed_ip_ranges
                .iter()
                .filter_map(|text| IpRange::parse(text))
                .collect(),
            targets: self.targets.iter().map(|t| t.entry.clone()).collect(),
        }
    }

    pub fn target_rules(&self) -> Vec<TargetRule> {
        self.targets.iter().map(rule_of).collect()
    }

    /// Правило выбранного VPN-приложения. В списке целей оно не появляется никогда:
    /// охрана, завершившая свой источник защиты, оставила бы состояние необратимым.
    pub fn vpn_app_rule(&self) -> Option<TargetRule> {
        self.vpn_app.as_ref().map(rule_of)
    }

    /// Выбор VPN-приложения снимает его же из целей — по той же причине.
    pub fn set_vpn_app(&mut self, app: Option<Target>) {
        if let Some(app) = &app {
            self.targets.retain(|t| t.entry != app.entry);
        }
        self.vpn_app = app;
    }
}

/// Правило матчера из записи настроек: путь запуска помнится вместе с текущим,
/// иначе сеанс, начатый до обновления цели, выпал бы из-под охраны.
fn rule_of(target: &Target) -> TargetRule {
    TargetRule {
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
    }
}
