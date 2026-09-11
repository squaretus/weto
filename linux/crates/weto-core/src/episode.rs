//! Учёт эпизода охраны: что уже описано в журнале.
//!
//! Правило одно на обе платформы (в macOS оно живёт в `GuardVM`), и держать
//! его в слое приложения нельзя: там нет тестов, а ошибка в нём видна только
//! на живой машине — записями «запуск запрещён» там, где процесс завершён
//! впервые.
//!
//! Два вопроса, на которые ledger отвечает: не описан ли уже этот процесс
//! по этой причине, и первое ли это завершение по такой причине.

use std::collections::HashSet;

#[derive(Debug, Default)]
pub struct EpisodeLedger {
    /// Пары «причина + pid», уже описанные в журнале.
    recorded: HashSet<(String, i32)>,
    /// Причины, уже описанные в рамках текущего эпизода.
    reasons: HashSet<String>,
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
    /// Дедупликация по паре, а не по одному pid: тот же процесс по другой
    /// причине (например, после «запуск запрещён» сменился повод) обязан
    /// получить свою запись.
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

    /// Цели снова работают: эпизод закрыт, и следующее завершение будет первым,
    /// а не «запуском запрещён».
    ///
    /// Обнуляется **всегда**, а не только когда эпизод был чем-то особенным:
    /// иначе следующее падение по той же причине писалось бы как «запуск
    /// запрещён», а множество пар росло бы до конца жизни процесса.
    pub fn finish(&mut self) {
        self.recorded.clear();
        self.reasons.clear();
    }
}
