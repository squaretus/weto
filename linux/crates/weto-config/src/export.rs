//! Журнал, выгруженный для разбора.
//!
//! Не голый массив записей, а конверт: по одним событиям не понять, что было
//! настроено в тот момент, а именно этот вопрос и задают, разбирая «почему цели
//! завершились». Формат общий с macOS — расхождение ловится голден-фикстурой
//! `shared/fixtures/journal-export.json`, которую гоняют оба тест-раннера.
//!
//! Токен ipinfo сюда не попадает: он не поле настроек, а отдельный файл,
//! и в трассах его нет, потому что уходит заголовком.

use std::time::SystemTime;

use serde::{Deserialize, Serialize};

use crate::checks::CheckEvent;
use crate::journal::KillEvent;
use crate::settings::Settings;

/// Версия формата. Меняется, когда старый разбор перестаёт понимать новый файл.
/// Версия 2: рядом с завершениями появились проверки.
pub const SCHEMA_VERSION: u32 = 2;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JournalExport {
    pub schema_version: u32,
    #[serde(with = "weto_core::timestamp::iso8601")]
    pub exported_at: SystemTime,
    pub app: ExportedApp,
    pub settings: ExportedSettings,
    pub events: Vec<KillEvent>,
    /// Попытки проверки подключения — включая те, где запрос так и не ушёл.
    /// Журнал завершений про них молчит: проверка, не породившая завершения,
    /// следа не оставляет, а «нажал и ничего не произошло» разбирают именно тут.
    pub checks: Vec<CheckEvent>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportedApp {
    pub version: String,
    pub platform: String,
    pub os_version: String,
}

/// Снимок настроек без единого секрета.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportedSettings {
    pub is_enabled: bool,
    pub vpn_app_rule: Option<String>,
    pub targets: Vec<String>,
    pub blocked_countries: Vec<String>,
    #[serde(rename = "blockedIPRanges")]
    pub blocked_ip_ranges: Vec<String>,
    pub allowed_countries: Vec<String>,
    #[serde(rename = "allowedIPRanges")]
    pub allowed_ip_ranges: Vec<String>,
    /// Токена нет и быть не может. Признак «задан ли» при этом полезен —
    /// без него отказ ipinfo не объяснить.
    #[serde(rename = "hasIPInfoToken")]
    pub has_ipinfo_token: bool,
}

impl JournalExport {
    pub fn build(
        settings: &Settings,
        events: Vec<KillEvent>,
        checks: Vec<CheckEvent>,
        has_token: bool,
        exported_at: SystemTime,
        os_version: String,
    ) -> JournalExport {
        let mut blocked_countries = settings.blocked_countries.clone();
        blocked_countries.sort();
        let mut allowed_countries = settings.allowed_countries.clone();
        allowed_countries.sort();

        JournalExport {
            schema_version: SCHEMA_VERSION,
            exported_at,
            app: ExportedApp {
                version: env!("CARGO_PKG_VERSION").to_string(),
                platform: "Linux".to_string(),
                os_version,
            },
            settings: ExportedSettings {
                is_enabled: settings.is_enabled,
                vpn_app_rule: settings.vpn_app.as_ref().map(|app| app.entry.clone()),
                targets: settings.targets.iter().map(|t| t.entry.clone()).collect(),
                blocked_countries,
                blocked_ip_ranges: settings.blocked_ip_ranges.clone(),
                allowed_countries,
                allowed_ip_ranges: settings.allowed_ip_ranges.clone(),
                has_ipinfo_token: has_token,
            },
            events,
            checks,
        }
    }

    /// Файл читают и человек, и агент, поэтому он с отступами: разница двух
    /// выгрузок должна быть разницей событий, а не форматирования.
    pub fn encoded(&self) -> serde_json::Result<String> {
        serde_json::to_string_pretty(self)
    }

    /// Имя файла по умолчанию: с точностью до минуты и без пробелов, чтобы его
    /// можно было приложить куда угодно, не переименовывая.
    pub fn file_name(stamp: &str) -> String {
        format!("weto-journal-{stamp}.json")
    }
}
