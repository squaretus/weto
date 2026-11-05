//! История возврата целей в терминал: автоматическая попытка → кнопка → подсказка.
//!
//! Порт `macos/Sources/WetoCore/TerminalReturnTracker.swift`. Под tmux шелл панели на время
//! паузы забирает терминал, и SIGCONT оставляет цель в фоне: `claude` перерисовывает интерфейс
//! и выглядит вернувшейся, а клавиши идут шеллу. Вернуть терминал может только `fg`, поэтому
//! охрана вводит его сама. Команда возвратом не считается: `fg` мог достаться другому заданию, —
//! решает наблюдение, что цель снова впереди.

use std::collections::{HashMap, HashSet};
use std::time::{Duration, SystemTime};

/// Сколько ждать, что отправленная команда подействует.
pub const VERIFY_WINDOW: Duration = Duration::from_secs(3);

/// Сколько живёт кнопка. Считается от снятия паузы, а не от показа кнопки.
pub const OFFER_WINDOW: Duration = Duration::from_secs(300);

/// Что сейчас с целью, оставшейся в фоне после снятия паузы.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalReturnState {
    /// Команда ушла или вот-вот уйдёт; ответ — наблюдение, что цель снова впереди.
    Returning,
    /// Автоматика не смогла: кнопка «Вернуть в терминал».
    Offered,
    /// Нажатие не помогло: поднято окно терминала, остаётся подсказка про `fg`.
    Failed,
    /// Кнопку не нажали за пять минут, цель всё ещё в фоне.
    Expired,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TerminalReturnStep {
    /// Кому положена автоматическая попытка прямо сейчас.
    pub attempts: Vec<i32>,
    /// Чьё нажатие только что не сработало: вызывающему поднимать окно терминала.
    pub failed: Vec<i32>,
}

#[derive(Debug, Clone)]
struct Entry {
    state: TerminalReturnState,
    since: SystemTime,
    is_press: bool,
    command_sent_at: Option<SystemTime>,
}

impl Entry {
    fn settled(&self) -> TerminalReturnState {
        if self.is_press {
            TerminalReturnState::Failed
        } else {
            TerminalReturnState::Offered
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct TerminalReturnTracker {
    entries: HashMap<i32, Entry>,
}

impl TerminalReturnTracker {
    pub fn state(&self, pid: i32) -> Option<TerminalReturnState> {
        self.entries.get(&pid).map(|entry| entry.state)
    }

    pub fn states(&self) -> HashMap<i32, TerminalReturnState> {
        self.entries
            .iter()
            .map(|(pid, entry)| (*pid, entry.state))
            .collect()
    }

    /// Такт: кто из целей сейчас ждёт возврата. Пустой список значит «ждать нечего» —
    /// цель вернулась, умерла или идёт новая пауза, на которой возвращать нельзя.
    pub fn observe(&mut self, waiting: &HashSet<i32>, now: SystemTime) -> TerminalReturnStep {
        self.entries.retain(|pid, _| waiting.contains(pid));

        let mut failed = Vec::new();
        for (pid, entry) in self.entries.iter_mut() {
            match entry.state {
                TerminalReturnState::Returning => {
                    let verified = entry
                        .command_sent_at
                        .is_some_and(|sent| elapsed(sent, now) >= VERIFY_WINDOW);
                    if verified {
                        entry.state = entry.settled();
                        if entry.state == TerminalReturnState::Failed {
                            failed.push(*pid);
                        }
                    }
                }
                TerminalReturnState::Offered => {
                    if elapsed(entry.since, now) >= OFFER_WINDOW {
                        entry.state = TerminalReturnState::Expired;
                    }
                }
                TerminalReturnState::Failed | TerminalReturnState::Expired => {}
            }
        }
        failed.sort_unstable();

        let mut attempts: Vec<i32> = waiting
            .iter()
            .copied()
            .filter(|pid| !self.entries.contains_key(pid))
            .collect();
        attempts.sort_unstable();
        for pid in &attempts {
            self.entries.insert(
                *pid,
                Entry {
                    state: TerminalReturnState::Returning,
                    since: now,
                    is_press: false,
                    command_sent_at: None,
                },
            );
        }
        TerminalReturnStep { attempts, failed }
    }

    /// Нажатие кнопки. Живёт до первого нажатия: `false`, если нажимать уже нечего.
    pub fn press(&mut self, pid: i32) -> bool {
        let Some(entry) = self
            .entries
            .get_mut(&pid)
            .filter(|entry| entry.state == TerminalReturnState::Offered)
        else {
            return false;
        };
        entry.state = TerminalReturnState::Returning;
        entry.is_press = true;
        entry.command_sent_at = None;
        true
    }

    /// Команда отработала. Успех возвратом не считается: ждём наблюдения.
    pub fn finished(&mut self, pid: i32, succeeded: bool, now: SystemTime) {
        let Some(entry) = self
            .entries
            .get_mut(&pid)
            .filter(|entry| entry.state == TerminalReturnState::Returning)
        else {
            return;
        };
        if succeeded {
            entry.command_sent_at = Some(now);
        } else {
            entry.state = entry.settled();
        }
    }
}

/// Часы, ушедшие назад, не считаются прошедшим временем.
fn elapsed(from: SystemTime, to: SystemTime) -> Duration {
    to.duration_since(from).unwrap_or(Duration::ZERO)
}
