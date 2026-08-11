//! Модели гео-пробы: чтение, исход, источник подтверждения.
//!
//! Разбор ответов сервисов и классификация отказа живут здесь же, но приходят
//! отдельной задачей. Сюда с границы попадают только данные и числа — никаких
//! HTTP-типов, иначе инвариант `weto-core` перестанет держаться.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ConfirmSource {
    Freeipapi,
    Geojs,
}

impl ConfirmSource {
    pub fn parse(raw: &str) -> Option<ConfirmSource> {
        match raw {
            "freeipapi" => Some(ConfirmSource::Freeipapi),
            "geojs" => Some(ConfirmSource::Geojs),
            _ => None,
        }
    }

    /// Имя источника попадает в причину завершения и на экран: пользователь
    /// должен видеть, кто именно назвал страну.
    pub fn name(self) -> &'static str {
        match self {
            ConfirmSource::Freeipapi => "freeipapi",
            ConfirmSource::Geojs => "geojs",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GeoReading {
    pub ip: String,
    pub primary_country: String,
    pub confirmed_country: Option<String>,
    pub confirm_source: Option<ConfirmSource>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum GeoOutcome {
    Resolved(GeoReading),
    /// Текст объясняет, кто именно промолчал: «Ipinfo недоступен» полезнее,
    /// чем «сервис недоступен».
    Unavailable(String),
}
