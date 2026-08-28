//! Журнал проверок подключения: кольцевой буфер на пятьдесят записей.
//!
//! Отдельным файлом от журнала завершений: это разные вопросы, и смешивать их
//! в одном буфере значило бы, что одно вытесняет другое. Пишется сразу на диск,
//! как и журнал завершений: кнопка выгрузки ничего не собирает заново, она пакует
//! уже написанное.

use std::path::Path;

use serde::{Deserialize, Serialize};

pub use weto_core::check::{CheckEvent, CheckOutcome, CheckTrigger};

/// Пятьдесят записей: журнал про попытки, а не про завершения, и нужен только
/// выгрузке. Число общее для обеих платформ — см. `Constants.checkLogCapacity`.
pub const CAPACITY: usize = 50;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CheckLog {
    entries: Vec<CheckEvent>,
}

impl CheckLog {
    pub fn entries(&self) -> &[CheckEvent] {
        &self.entries
    }

    pub fn clear(&mut self) {
        self.entries.clear();
    }

    /// Рутинная удача расписания отсеивается здесь, а не у вызывающего: решение
    /// «что достойно записи» — свойство события, и оно одно на все места,
    /// откуда проверки приходят.
    pub fn append(&mut self, event: CheckEvent) -> bool {
        if !event.is_worth_recording() {
            return false;
        }
        self.entries.push(event);
        if self.entries.len() > CAPACITY {
            let excess = self.entries.len() - CAPACITY;
            self.entries.drain(0..excess);
        }
        true
    }

    /// Испорченный журнал не должен мешать охране: он не данные пользователя,
    /// а история. Читается как пустой.
    pub fn load(path: &Path) -> CheckLog {
        std::fs::read_to_string(path)
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default()
    }

    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let text = serde_json::to_string_pretty(self)?;
        let temporary = path.with_extension("json.tmp");
        std::fs::write(&temporary, text)?;
        std::fs::rename(&temporary, path)
    }
}
