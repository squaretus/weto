//! Журнал завершений: кольцевой буфер на десять записей.
//!
//! Правило записи перенесено с macOS дословно: в рамках одного эпизода
//! записывается каждый новый pid, а причина у записи одна — та, что выяснилась
//! последней. «Подключение ещё не проверено» приходит первым, потому что
//! fail-closed срабатывает раньше вердикта, и уточняется, как только вердикт
//! готов: второй записи не будет — завершать к тому моменту уже нечего.

use std::path::Path;
use std::time::SystemTime;

use serde::{Deserialize, Serialize};

pub const CAPACITY: usize = 10;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum KillEventKind {
    Terminated,
    LaunchBlocked,
}

impl KillEventKind {
    pub fn display_text(self) -> &'static str {
        match self {
            KillEventKind::Terminated => "завершено",
            KillEventKind::LaunchBlocked => "запуск запрещён",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KillEvent {
    pub at: SystemTime,
    pub target_names: Vec<String>,
    pub kind: KillEventKind,
    pub reason_text: String,
    pub ip: Option<String>,
    pub country: Option<String>,
    pub confirmed_country: Option<String>,
    pub confirm_source: Option<String>,
    pub killed_pids: Vec<i32>,
}

impl KillEvent {
    pub fn targets_text(&self) -> String {
        if self.target_names.is_empty() {
            "неизвестная цель".to_string()
        } else {
            self.target_names.join(", ")
        }
    }

    pub fn summary_text(&self) -> String {
        format!(
            "{} — {}",
            self.kind.display_text(),
            lowercasing_first_word(&self.reason_text)
        )
    }
}

/// Аббревиатуру не трогаем: «VPN не поднят» не должно стать «vPN не поднят».
fn lowercasing_first_word(text: &str) -> String {
    let mut characters = text.chars();
    let Some(first) = characters.next() else {
        return String::new();
    };
    let rest: String = characters.collect();

    if rest.chars().next().is_some_and(|c| c.is_uppercase()) {
        return text.to_string();
    }
    first.to_lowercase().collect::<String>() + &rest
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Journal {
    entries: Vec<KillEvent>,
}

impl Journal {
    pub fn entries(&self) -> &[KillEvent] {
        &self.entries
    }

    pub fn clear(&mut self) {
        self.entries.clear();
    }

    pub fn append(&mut self, event: KillEvent) {
        self.entries.push(event);
        if self.entries.len() > CAPACITY {
            let excess = self.entries.len() - CAPACITY;
            self.entries.drain(0..excess);
        }
    }

    /// Причина эпизода, ставшая известной, дописывается в его запись.
    ///
    /// Fail-closed завершает цели раньше вердикта, и первой в журнал попадает
    /// «подключение ещё не проверено» — ответ «пока не знаю». Секундой позже
    /// причина известна, но завершать уже нечего, и второй записи не будет:
    /// журнал навсегда сохранял отговорку вместо того, из-за чего цели и умерли.
    /// `false` — уточнять нечего, эпизод записи не оставил.
    pub fn refine_last_reason(&mut self, reason_text: &str) -> bool {
        match self.entries.last_mut() {
            Some(event) => {
                event.reason_text = reason_text.to_string();
                true
            }
            None => false,
        }
    }

    /// Испорченный журнал не должен мешать охране: он не данные пользователя,
    /// а история. Читается как пустой.
    pub fn load(path: &Path) -> Journal {
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
