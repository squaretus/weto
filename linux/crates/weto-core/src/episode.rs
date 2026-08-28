//! Учёт эпизода охраны: что уже описано в журнале.
//!
//! Правило одно на обе платформы (в macOS оно живёт в `GuardVM`), и держать
//! его в слое приложения нельзя: там нет тестов, а ошибка в нём видна только
//! на живой машине — записями «запуск запрещён» там, где процесс завершён
//! впервые.
//!
//! Три вопроса, на которые ledger отвечает: не описан ли уже этот процесс
//! по этой причине; первое ли это завершение по такой причине; и чем стало
//! известное имя причины, когда «подключение ещё не проверено» уточнилось.

use std::collections::HashSet;

#[derive(Debug, Default)]
pub struct EpisodeLedger {
    /// Пары «причина + pid», уже описанные в журнале.
    recorded: HashSet<(String, i32)>,
    /// Причины, уже описанные в рамках текущего эпизода.
    reasons: HashSet<String>,
    /// Эпизод, записанный до вердикта: его причину предстоит уточнить.
    pending_id: Option<String>,
}

impl EpisodeLedger {
    pub fn new() -> EpisodeLedger {
        EpisodeLedger::default()
    }

    /// Первое ли это завершение по такой причине. От ответа зависит вид записи:
    /// «завершено» или «запуск запрещён».
    pub fn is_new_reason(&self, reason: &str) -> bool {
        !self.reasons.contains(reason)
    }

    /// Какие из завершённых процессов ещё не описаны по этой причине.
    ///
    /// Дедупликация по паре, а не по одному pid: уточнённая причина иначе
    /// считалась бы новой и завела бы второй набор записей про то же падение.
    pub fn fresh<'a, T>(
        &self,
        killed: &'a [T],
        reason: &str,
        pid: impl Fn(&T) -> i32,
    ) -> Vec<&'a T> {
        killed
            .iter()
            .filter(|item| !self.recorded.contains(&(reason.to_string(), pid(item))))
            .collect()
    }

    pub fn remember(&mut self, reason: &str, pids: impl IntoIterator<Item = i32>) {
        self.reasons.insert(reason.to_string());
        for pid in pids {
            self.recorded.insert((reason.to_string(), pid));
        }
    }

    pub fn begin_pending(&mut self, episode_id: String) {
        self.pending_id = Some(episode_id);
    }

    /// Причина эпизода стала известна: ключ дедупликации переезжает вместе
    /// с текстом, иначе те же процессы того же эпизода выглядят новыми.
    ///
    /// Возвращает эпизод, которому надо дописать причину, — или `None`,
    /// если уточнять нечего.
    pub fn settle(&mut self, pending_reason: &str, settled_reason: &str) -> Option<String> {
        let pending_id = self.pending_id.take()?;

        self.reasons.remove(pending_reason);
        self.reasons.insert(settled_reason.to_string());
        self.recorded = self
            .recorded
            .drain()
            .map(|(reason, pid)| {
                if reason == pending_reason {
                    (settled_reason.to_string(), pid)
                } else {
                    (reason, pid)
                }
            })
            .collect();

        Some(pending_id)
    }

    /// Эпизод кончился безопасным выходом.
    ///
    /// Учёт обнуляется **всегда**, а не только когда эпизод был неразобранным:
    /// иначе следующее падение по той же причине писалось бы как «запуск
    /// запрещён», а множество пар росло бы до конца жизни процесса.
    /// Возвращает эпизод, которому надо дописать исход, если тот был пендингом.
    pub fn finish(&mut self) -> Option<String> {
        let pending_id = self.pending_id.take();
        self.recorded.clear();
        self.reasons.clear();
        pending_id
    }
}
