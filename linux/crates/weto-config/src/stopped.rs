//! Учёт остановленных процессов: `$XDG_STATE_HOME/weto/stopped.json`.
//!
//! Порт `StoppedLedger` с macOS. Без него цели, остановленные перед падением
//! weto, остаются замороженными навсегда: файл читается на старте, и все ещё
//! стоящие процессы из него получают SIGCONT. Отдельным файлом от журналов
//! намеренно: журнал — история, учёт — обязательство, и вытеснять обязательство
//! кольцевым буфером нельзя.
//!
//! Учёт ведёт охрана: запись заводит пауза, вычёркивает её наблюдение —
//! процесса больше нет или ядро показало его идущим, — а не сам факт отправки
//! SIGCONT. Записи, дожившие до нового запуска, разбирает восстановление
//! на старте.

use std::collections::HashSet;
use std::path::Path;
use std::time::SystemTime;

use serde::{Deserialize, Serialize};

/// Процесс, которому weto послал SIGSTOP. Путь хранится ради защиты
/// от переиспользования pid: после падения weto по этому же pid может жить
/// уже другой процесс.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StoppedProcess {
    pub pid: i32,
    pub executable_path: String,
    #[serde(with = "weto_core::timestamp::iso8601")]
    pub stopped_at: SystemTime,
    /// Шелл переднего задания — остановлен ради терминала цели, целью не является.
    pub is_shell: bool,
}

/// Итог чтения учёта с диска. Различает «файла нет или он пуст» и «файл был,
/// но не прочитался»: без этого испорченный `stopped.json` неотличим от пустого,
/// и процессы, которых он должен был вернуть из паузы, остаются замороженными
/// молча. Механизм восстановления, не сумевший прочитать собственный файл,
/// обязан оставить след.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StoppedLedgerReadout {
    Entries(Vec<StoppedProcess>),
    Corrupted,
}

impl StoppedLedgerReadout {
    /// Файла нет — легитимно пусто. Файл есть, но не разобрался — `Corrupted`:
    /// тоже пустой список, но с видимым отличием на границе.
    pub fn load(path: &Path) -> StoppedLedgerReadout {
        let Ok(text) = std::fs::read_to_string(path) else {
            return StoppedLedgerReadout::Entries(Vec::new());
        };
        match serde_json::from_str::<Vec<StoppedProcess>>(&text) {
            Ok(entries) => StoppedLedgerReadout::Entries(entries),
            Err(_) => StoppedLedgerReadout::Corrupted,
        }
    }

    /// Записи независимо от исхода: старт приложения не блокируется ни разу,
    /// испорченный файл читается как пустой ровно так же, как отсутствующий.
    pub fn entries(&self) -> &[StoppedProcess] {
        match self {
            StoppedLedgerReadout::Entries(entries) => entries,
            StoppedLedgerReadout::Corrupted => &[],
        }
    }

    pub fn is_corrupted(&self) -> bool {
        matches!(self, StoppedLedgerReadout::Corrupted)
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct StoppedLedger {
    entries: Vec<StoppedProcess>,
    started_from_corrupted_file: bool,
}

impl StoppedLedger {
    pub fn load(path: &Path) -> StoppedLedger {
        let readout = StoppedLedgerReadout::load(path);
        StoppedLedger {
            entries: readout.entries().to_vec(),
            started_from_corrupted_file: readout.is_corrupted(),
        }
    }

    pub fn entries(&self) -> &[StoppedProcess] {
        &self.entries
    }

    /// Истинно, если на старте файл учёта был испорчен: `entries` при этом
    /// всё равно пуст и запуск не заблокирован, но обязательство «вернуть
    /// остановленным SIGCONT» выполнено не было, и сказать об этом некому,
    /// кроме этого признака.
    pub fn started_from_corrupted_file(&self) -> bool {
        self.started_from_corrupted_file
    }

    pub fn pids(&self) -> Vec<i32> {
        self.entries.iter().map(|entry| entry.pid).collect()
    }

    /// Порядок добавления сохраняется: продолжение идёт по нему в обратную
    /// сторону. `false` — учёт не изменился, и писать файл незачем.
    ///
    /// Повтором считается та же пара «pid + путь» — ровно та, по которой запись
    /// опознают `ProcessEnforcer::pause` и `settle`. Прежняя запись с тем же pid,
    /// но другим путём, заведомо мертва: двум живым процессам одно число ядро
    /// не выдаёт, — и она уступает место свежей. Иначе свежая терялась целиком:
    /// SIGSTOP ей уже послан, в учёт она не попадала, а следующий проход вычёркивал
    /// по несовпадению путей чужую запись — и размораживать цель становилось некому.
    ///
    /// Свежая запись встаёт в хвост, а не на место вытесненной: учёт хранит
    /// порядок остановки, и остановлена она сейчас — позже всего, что уже лежит.
    pub fn add(&mut self, fresh: &[StoppedProcess]) -> bool {
        let known: HashSet<(i32, &str)> = self
            .entries
            .iter()
            .map(|entry| (entry.pid, entry.executable_path.as_str()))
            .collect();
        let additions: Vec<StoppedProcess> = fresh
            .iter()
            .filter(|entry| !known.contains(&(entry.pid, entry.executable_path.as_str())))
            .cloned()
            .collect();
        if additions.is_empty() {
            return false;
        }
        let recycled: HashSet<i32> = additions.iter().map(|entry| entry.pid).collect();
        self.entries.retain(|entry| !recycled.contains(&entry.pid));
        self.entries.extend(additions);
        true
    }

    pub fn remove(&mut self, pids: &[i32]) -> bool {
        let before = self.entries.len();
        self.entries.retain(|entry| !pids.contains(&entry.pid));
        before != self.entries.len()
    }

    pub fn clear(&mut self) -> bool {
        if self.entries.is_empty() {
            return false;
        }
        self.entries.clear();
        true
    }

    /// Запись атомарна: временный файл рядом и `rename` поверх. Учёт переживает
    /// SIGKILL самому weto — иначе он не учёт, а пожелание.
    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let text = serde_json::to_string_pretty(&self.entries)?;
        let temporary = path.with_extension("json.tmp");
        std::fs::write(&temporary, text)?;
        std::fs::rename(&temporary, path)
    }
}
