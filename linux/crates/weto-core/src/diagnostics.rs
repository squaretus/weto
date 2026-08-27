//! Отладочные показания завершения: не показываются пользователю, уходят в выгрузку.
//!
//! Зеркало макосного `KillDiagnostics`. Живут в ядре, а не в хранилище, потому что
//! собирает их охрана, а хранилище только записывает.

use std::time::SystemTime;

use serde::{Deserialize, Serialize};

/// Почему прежний вердикт перестал быть свежим.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum StalenessCause {
    ColdStart,
    ConfigurationChanged,
    NetworkChanged,
    ConfigurationAndNetworkChanged,
}

impl StalenessCause {
    pub fn display_text(self) -> &'static str {
        match self {
            StalenessCause::ColdStart => "вердикта ещё не было",
            StalenessCause::ConfigurationChanged => "изменились настройки",
            StalenessCause::NetworkChanged => "сменился выход в сеть",
            StalenessCause::ConfigurationAndNetworkChanged => {
                "изменились и настройки, и выход в сеть"
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VerdictStaleness {
    pub cause: StalenessCause,
    pub previous_revision: Option<u64>,
    pub revision: u64,
    pub previous_fingerprint: Option<String>,
    pub fingerprint: String,
}

impl VerdictStaleness {
    pub fn new(
        previous_revision: Option<u64>,
        revision: u64,
        previous_fingerprint: Option<String>,
        fingerprint: String,
    ) -> VerdictStaleness {
        let cause = match (previous_revision, previous_fingerprint.as_deref()) {
            (Some(old), Some(old_fingerprint)) => {
                match (old != revision, old_fingerprint != fingerprint) {
                    (true, true) => StalenessCause::ConfigurationAndNetworkChanged,
                    (true, false) => StalenessCause::ConfigurationChanged,
                    (false, true) => StalenessCause::NetworkChanged,
                    (false, false) => StalenessCause::ColdStart,
                }
            }
            _ => StalenessCause::ColdStart,
        };

        VerdictStaleness {
            cause,
            previous_revision,
            revision,
            previous_fingerprint,
            fingerprint,
        }
    }

    /// «сменился выход в сеть: out=wg0/10.2.0.2 → out=wg0/10.2.0.5».
    pub fn display_text(&self) -> String {
        match (self.cause, self.previous_fingerprint.as_deref()) {
            (
                StalenessCause::NetworkChanged | StalenessCause::ConfigurationAndNetworkChanged,
                Some(previous),
            ) => format!(
                "{}: {} → {}",
                self.cause.display_text(),
                previous,
                self.fingerprint
            ),
            _ => self.cause.display_text().to_string(),
        }
    }
}

/// Что ответил один гео-сервис в одной пробе — как есть, до разбора.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GeoServiceTrace {
    pub service: String,
    /// Токена в адресе нет никогда: ipinfo принимает его заголовком,
    /// а заголовки в журнал не попадают вовсе.
    pub url: String,
    pub http_status: Option<u16>,
    pub duration_milliseconds: Option<u64>,
    pub body: Option<String>,
    pub failure: Option<String>,
    pub from_cache: bool,
    pub cache_age_seconds: Option<u64>,
}

/// Потолок сырого тела. Ответы гео-сервисов — сотни байт; всё, что заметно
/// больше, это страница-заглушка провайдера или капча, и для опознания
/// её хватает начала.
pub const BODY_LIMIT: usize = 4096;

impl GeoServiceTrace {
    pub fn trimmed(body: &str) -> String {
        if body.chars().count() <= BODY_LIMIT {
            return body.to_string();
        }
        let head: String = body.chars().take(BODY_LIMIT).collect();
        format!("{head}…(обрезано)")
    }
}

/// Всё, что известно о завершении, но не показывается пользователю.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KillDiagnostics {
    pub staleness: Option<VerdictStaleness>,
    pub outgoing_interface: Option<String>,
    pub outgoing_address: Option<String>,
    pub has_network_path: Option<bool>,
    pub vpn_app_entry: Option<String>,
    pub vpn_app_status: Option<String>,
    #[serde(default)]
    pub services: Vec<GeoServiceTrace>,
    #[serde(default, with = "crate::timestamp::iso8601_option")]
    pub probed_at: Option<SystemTime>,
    pub app_version: Option<String>,
}

/// Показания вердикта, дописываемые эпизоду.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GeoReadingPatch {
    pub ip: Option<String>,
    pub country: Option<String>,
    pub confirmed_country: Option<String>,
    pub confirm_source: Option<String>,
}

/// Контекст завершения: всё, что охрана знает в момент, когда пишет журнал.
///
/// Одним параметром, а не пятью: приёмник у трейта один, и добавлять к нему
/// аргумент на каждое новое показание — значит править и все тестовые двойники.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct KillContext {
    pub reason: String,
    /// Эпизод начался до вердикта: причина ещё «подключение не проверено»,
    /// и её предстоит уточнить.
    pub is_pending: bool,
    pub reading: GeoReadingPatch,
    pub diagnostics: KillDiagnostics,
}
