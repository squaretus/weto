//! Одна попытка проверки подключения.
//!
//! Журнал завершений отвечает на вопрос «почему умерли цели». На вопрос «я нажал
//! проверить, и ничего не произошло» он не отвечает вовсе: нажатие, не породившее
//! завершения, следа не оставляет. Отсюда второй журнал — про сами проверки,
//! включая те, где запрос так и не ушёл.
//!
//! Зеркало макосного `CheckEvent`. В интерфейс не попадает никогда: это материал
//! выгрузки.

use std::time::SystemTime;

use serde::{Deserialize, Serialize};

use crate::diagnostics::GeoServiceTrace;

/// Что вызвало проверку.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CheckTrigger {
    /// Кнопка «проверить» в окне статуса.
    Manual,
    /// Сменился путь наружу — интерфейс или локальный адрес.
    NetworkChange,
    /// Расписание гео.
    Schedule,
    /// Правка настроек обесценила вердикт.
    SettingsChange,
}

impl CheckTrigger {
    pub fn display_text(self) -> &'static str {
        match self {
            CheckTrigger::Manual => "кнопка «проверить»",
            CheckTrigger::NetworkChange => "сменился путь наружу",
            CheckTrigger::Schedule => "расписание",
            CheckTrigger::SettingsChange => "правка настроек",
        }
    }
}

/// Чем попытка кончилась.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CheckOutcome {
    /// Запрос ушёл и вернулся с адресом и страной.
    Answered,
    /// Запрос ушёл, но годного ответа не дал.
    Failed,
    /// Запрос не ушёл: другая проба ещё в полёте. Ровно это и означает
    /// «нажал пять раз, а ничего не поехало».
    SkippedProbeInFlight,
    /// Ответ пришёл, но описывает уже не нас: путь сменился, пока проба летела.
    DiscardedPathChanged,
    /// Ответ пришёл, но настройки успели измениться.
    DiscardedSettingsChanged,
}

impl CheckOutcome {
    pub fn display_text(self) -> &'static str {
        match self {
            CheckOutcome::Answered => "ответ получен",
            CheckOutcome::Failed => "ответа нет",
            CheckOutcome::SkippedProbeInFlight => "запрос не отправлен: проба уже в полёте",
            CheckOutcome::DiscardedPathChanged => "ответ отброшен: путь сменился",
            CheckOutcome::DiscardedSettingsChanged => "ответ отброшен: настройки изменились",
        }
    }

    /// Запрос действительно ушёл и вернулся ни с чем — единственное, что стоит
    /// записывать из расписания.
    pub fn is_failed_request(self) -> bool {
        self == CheckOutcome::Failed
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckEvent {
    pub id: String,
    #[serde(rename = "date", with = "crate::timestamp::iso8601")]
    pub at: SystemTime,
    pub trigger: CheckTrigger,
    pub outcome: CheckOutcome,

    /// Отпечаток выхода на момент проверки: интерфейс и локальный адрес.
    pub fingerprint: Option<String>,
    pub duration_milliseconds: Option<u64>,

    pub ip: Option<String>,
    pub country: Option<String>,
    pub confirmed_country: Option<String>,
    pub confirm_source: Option<String>,

    #[serde(default)]
    pub services: Vec<GeoServiceTrace>,

    /// Подробность отказа — то, что не выражается кодом исхода.
    pub detail: Option<String>,
}

impl CheckEvent {
    /// Пишется ли такая проверка в журнал.
    ///
    /// Всё, что попросил пользователь или потребовала смена обстановки, пишется
    /// всегда. Из расписания — только состоявшийся запрос без ответа: рутина
    /// раз в пять секунд съела бы ёмкость за четыре минуты и не сказала бы ничего.
    pub fn is_worth_recording(&self) -> bool {
        match self.trigger {
            CheckTrigger::Manual | CheckTrigger::NetworkChange | CheckTrigger::SettingsChange => {
                true
            }
            CheckTrigger::Schedule => self.outcome.is_failed_request(),
        }
    }
}
