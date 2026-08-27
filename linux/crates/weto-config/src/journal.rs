//! Журнал завершений: кольцевой буфер на сто записей, по записи на процесс.
//!
//! Правило записи перенесено с macOS дословно. Запись описывает один завершённый
//! процесс, а проход охраны склеивается `episode_id`: «claude» и тридцать четыре
//! pid одной строкой не отвечали на главный вопрос — что именно завершилось
//! и почему их столько.
//!
//! «Подключение ещё не проверено» приходит первым, потому что fail-closed
//! срабатывает раньше вердикта, и уточняется, как только вердикт готов: второй
//! записи не будет — завершать к тому моменту уже нечего. Эпизод, закончившийся
//! безопасным выходом, дописывает исход: без него запись навсегда оставалась
//! с отговоркой, и завершение выглядело беспричинным.

use std::path::Path;
use std::time::SystemTime;

use serde::{Deserialize, Serialize};

pub use weto_core::diagnostics::{
    GeoReadingPatch, GeoServiceTrace, KillContext, KillDiagnostics, StalenessCause,
    VerdictStaleness, BODY_LIMIT,
};

/// Сто записей, а не десять: запись теперь на процесс, и одно падение VPN
/// на тридцати четырёх процессах вытесняло прежний журнал целиком.
/// Число общее для обеих платформ — см. `Constants.eventLogCapacity` в macOS-части.
pub const CAPACITY: usize = 100;

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

/// Один завершённый процесс.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KillEvent {
    pub id: String,
    /// Общий для всех процессов, завершённых одним проходом охраны.
    #[serde(rename = "episodeID")]
    pub episode_id: String,
    /// В файле — `date`: имя общее с macOS, где поле так и называется.
    #[serde(rename = "date", with = "weto_core::timestamp::iso8601")]
    pub at: SystemTime,

    pub target_name: String,
    pub pid: i32,
    #[serde(default, rename = "parentPID")]
    pub parent_pid: i32,
    #[serde(default)]
    pub executable_path: String,
    #[serde(default)]
    pub is_descendant: bool,

    pub kind: KillEventKind,
    pub reason_text: String,
    /// Чем эпизод закончился. Дописывается и тогда, когда проверка в итоге
    /// сказала «безопасно», — именно этот случай выглядит как «weto завершает
    /// процессы случайно».
    pub resolution_text: Option<String>,

    pub ip: Option<String>,
    pub country: Option<String>,
    pub confirmed_country: Option<String>,
    pub confirm_source: Option<String>,

    pub diagnostics: Option<KillDiagnostics>,
}

impl KillEvent {
    pub fn summary_text(&self) -> String {
        format!(
            "{} — {}",
            self.kind.display_text(),
            lowercasing_first_word(&self.reason_text)
        )
    }

    /// Цель и её процесс: записей на одно падение столько, сколько процессов
    /// завершено, и различать их можно только по pid.
    pub fn title(&self) -> String {
        let name = if self.target_name.is_empty() {
            "неизвестная цель"
        } else {
            &self.target_name
        };
        format!("{name} · pid {}", self.pid)
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

    /// Проход охраны пишется целиком: сколько процессов завершено, столько
    /// и записей.
    pub fn append(&mut self, events: Vec<KillEvent>) {
        self.entries.extend(events);
        if self.entries.len() > CAPACITY {
            let excess = self.entries.len() - CAPACITY;
            self.entries.drain(0..excess);
        }
    }

    /// Причина эпизода, ставшая известной, дописывается всем его записям.
    ///
    /// `false` — уточнять нечего, эпизод записи не оставил.
    pub fn refine_episode(
        &mut self,
        episode_id: &str,
        reason_text: Option<&str>,
        resolution_text: Option<&str>,
        reading: Option<&GeoReadingPatch>,
        diagnostics: Option<&KillDiagnostics>,
    ) -> bool {
        let mut touched = false;
        for event in self
            .entries
            .iter_mut()
            .filter(|event| event.episode_id == episode_id)
        {
            if let Some(reason) = reason_text {
                event.reason_text = reason.to_string();
            }
            if let Some(resolution) = resolution_text {
                event.resolution_text = Some(resolution.to_string());
            }
            if let Some(reading) = reading {
                event.ip = reading.ip.clone().or_else(|| event.ip.clone());
                event.country = reading.country.clone().or_else(|| event.country.clone());
                event.confirmed_country = reading
                    .confirmed_country
                    .clone()
                    .or_else(|| event.confirmed_country.clone());
                event.confirm_source = reading
                    .confirm_source
                    .clone()
                    .or_else(|| event.confirm_source.clone());
            }
            if let Some(diagnostics) = diagnostics {
                event.diagnostics = Some(diagnostics.clone());
            }
            touched = true;
        }
        touched
    }

    /// Испорченный журнал не должен мешать охране: он не данные пользователя,
    /// а история. Читается как пустой.
    pub fn load(path: &Path) -> Journal {
        let Ok(text) = std::fs::read_to_string(path) else {
            return Journal::default();
        };
        if let Ok(journal) = serde_json::from_str::<Journal>(&text) {
            return journal;
        }
        // Журнал прежнего формата не выбрасывается: он и есть история, ради
        // которой поднимали ёмкость. Одна старая запись про N процессов
        // разворачивается в N записей одного эпизода.
        serde_json::from_str::<LegacyJournal>(&text)
            .map(LegacyJournal::expanded)
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

#[derive(Debug, Deserialize)]
struct LegacyJournal {
    entries: Vec<LegacyKillEvent>,
}

/// Запись журнала до разбивки на процессы.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacyKillEvent {
    at: SystemTime,
    target_names: Vec<String>,
    kind: KillEventKind,
    reason_text: String,
    ip: Option<String>,
    country: Option<String>,
    confirmed_country: Option<String>,
    confirm_source: Option<String>,
    killed_pids: Vec<i32>,
}

impl LegacyJournal {
    fn expanded(self) -> Journal {
        let mut journal = Journal::default();
        for (index, legacy) in self.entries.into_iter().enumerate() {
            // Какой pid какой цели принадлежал, прежний формат не сохранял.
            // Выдумывать привязку нельзя, поэтому цели перечисляются как есть.
            let name = if legacy.target_names.is_empty() {
                "неизвестная цель".to_string()
            } else {
                legacy.target_names.join(", ")
            };
            let episode_id = format!("legacy-{index}");
            let expanded: Vec<KillEvent> = legacy
                .killed_pids
                .iter()
                .enumerate()
                .map(|(order, pid)| KillEvent {
                    id: format!("{episode_id}-{order}"),
                    episode_id: episode_id.clone(),
                    at: legacy.at,
                    target_name: name.clone(),
                    pid: *pid,
                    parent_pid: 0,
                    executable_path: String::new(),
                    is_descendant: false,
                    kind: legacy.kind,
                    reason_text: legacy.reason_text.clone(),
                    resolution_text: None,
                    ip: legacy.ip.clone(),
                    country: legacy.country.clone(),
                    confirmed_country: legacy.confirmed_country.clone(),
                    confirm_source: legacy.confirm_source.clone(),
                    diagnostics: None,
                })
                .collect();
            journal.append(expanded);
        }
        journal
    }
}
