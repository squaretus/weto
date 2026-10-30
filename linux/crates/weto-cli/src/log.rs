//! Лог охраны на переднем плане: строки в stdout с меткой времени.
//!
//! Уведомлений рабочего стола у терминальной версии нет — ни D-Bus, ни
//! `DesktopNotifier`: на сервере их показать некому. Те же события, о которых
//! приложение сообщает баннером, здесь уходят строкой в лог, а под systemd —
//! в журнал юнита (`journalctl -u weto`, у пользовательского — `--user`).

use std::sync::Arc;
use std::time::SystemTime;

use weto_config::journal::KillContext;
use weto_core::pause_plan::RecoveredProcess;
use weto_core::process::MatchedProcess;
use weto_guard::controller::{KillReporting, OutcomeException};
use weto_sys::notifications::KillNotifying;

/// Куда уходит строка лога. Метку времени ставит сам лог.
pub type LogSink = Arc<dyn Fn(&str) + Send + Sync>;

/// Строки в stdout. Stdout в Rust построчно буферизован, а systemd читает
/// его из канала — строка уходит в журнал юнита сразу.
pub fn stdout_sink() -> LogSink {
    Arc::new(|text: &str| println!("{} {text}", stamp(SystemTime::now())))
}

/// Метка `dd.MM.yyyy HH:mm:ss` в местном времени — тот же вид, что у журнала
/// в окне. Смещение берётся на печатаемый момент: запись до перевода часов
/// иначе показала бы чужой час.
pub fn stamp(at: SystemTime) -> String {
    weto_core::timestamp::to_local_display(at, utc_offset(at))
}

/// Смещение местного пояса от UTC в секундах на момент `at`.
pub fn utc_offset(at: SystemTime) -> i64 {
    // Тип секунд выводится из `localtime_r`, а не называется: под musl
    // `libc::time_t` объявлен устаревшим псевдонимом (ждёт 64-битного
    // `time_t` musl 1.2), и сборка статического бинарника предупреждала бы.
    let seconds = at
        .duration_since(SystemTime::UNIX_EPOCH)
        .ok()
        .and_then(|d| d.as_secs().try_into().ok())
        .unwrap_or_default();
    // SAFETY: localtime_r пишет только в переданную структуру и не держит
    // указателей после возврата.
    unsafe {
        let mut local: libc::tm = std::mem::zeroed();
        if libc::localtime_r(&seconds, &mut local).is_null() {
            return 0;
        }
        local.tm_gmtoff as i64
    }
}

/// «claude ×2, codex» — цели прохода, как в уведомлении приложения.
fn names(processes: &[MatchedProcess]) -> String {
    let mut order: Vec<&str> = Vec::new();
    let mut counts: std::collections::HashMap<&str, usize> = Default::default();
    for process in processes {
        let name = process.target_name.as_str();
        if !counts.contains_key(name) {
            order.push(name);
        }
        *counts.entry(name).or_default() += 1;
    }
    order
        .into_iter()
        .map(|name| match counts[name] {
            1 => name.to_string(),
            count => format!("{name} ×{count}"),
        })
        .collect::<Vec<_>>()
        .join(", ")
}

fn pid_list(processes: &[MatchedProcess]) -> String {
    processes
        .iter()
        .map(|p| p.pid.to_string())
        .collect::<Vec<_>>()
        .join(", ")
}

/// Уведомитель терминальной версии: то, что приложение показало бы баннером, —
/// строкой в лог.
///
/// Баннер о завершении приходит сюда без pid, а лог обязан их назвать,
/// поэтому завершение пишет `LoggingReporter` — он видит процессы целиком
/// и зовётся на каждом проходе, где кто-то завершён, то есть всегда, когда
/// пришёл бы и баннер. Здесь остаётся одно: цель, ушедшая в фон под паузой.
pub struct LogNotifier(pub LogSink);

impl KillNotifying for LogNotifier {
    fn notify(&self, _target_names: &[String], _reason: &str, _killed_count: usize) {}

    fn notify_backgrounded(&self, target_name: &str) {
        (self.0)(&format!(
            "{target_name}: процесс вернулся в фон. Откройте терминал и введите fg"
        ));
    }
}

/// Писатель журнала с логом поверх: завершение, пауза, причина паузы, названная
/// ответом пробы, исход паузы, освобождение и восстановление — строкой с именами
/// и pid, журнал — как у приложения.
pub struct LoggingReporter<R: KillReporting> {
    pub inner: R,
    pub log: LogSink,
}

impl<R: KillReporting> KillReporting for LoggingReporter<R> {
    fn report(
        &self,
        killed: &[MatchedProcess],
        recordable: &[MatchedProcess],
        context: &KillContext,
    ) {
        if !killed.is_empty() {
            (self.log)(&format!(
                "завершены: {} (pid {}) — {}",
                names(killed),
                pid_list(killed),
                context.reason
            ));
        }
        self.inner.report(killed, recordable, context);
    }

    fn episode_finished(&self, context: &KillContext) {
        self.inner.episode_finished(context);
    }

    fn paused(&self, stopped: &[MatchedProcess], context: &KillContext) {
        if !stopped.is_empty() {
            (self.log)(&format!(
                "на паузе: {} (pid {}) — {}",
                names(stopped),
                pid_list(stopped),
                context.reason
            ));
        }
        self.inner.paused(stopped, context);
    }

    fn backgrounded(&self, target_name: &str) {
        self.inner.backgrounded(target_name);
    }

    fn recovered(&self, standing: &[RecoveredProcess], context: &KillContext) {
        if !standing.is_empty() {
            let processes: Vec<MatchedProcess> =
                standing.iter().map(|r| r.process.clone()).collect();
            (self.log)(&format!(
                "стоят с прошлого запуска: {} (pid {}) — продолжаю",
                names(&processes),
                pid_list(&processes)
            ));
        }
        self.inner.recovered(standing, context);
    }

    fn pause_reason_named(&self, reason: &str) {
        (self.log)(&format!("причина паузы: {reason}"));
        self.inner.pause_reason_named(reason);
    }

    fn released(&self, pids: &[i32], outcome: &str, context: &KillContext) {
        if !pids.is_empty() {
            let list = pids
                .iter()
                .map(|pid| pid.to_string())
                .collect::<Vec<_>>()
                .join(", ");
            (self.log)(&format!("pid {list}: {outcome}"));
        }
        self.inner.released(pids, outcome, context);
    }

    fn pause_resolved(
        &self,
        outcome: &str,
        shell_outcome: Option<&str>,
        exceptions: &[OutcomeException],
        context: &KillContext,
    ) {
        (self.log)(&format!("исход паузы: {outcome}"));
        for exception in exceptions.iter().filter(|e| !e.pids.is_empty()) {
            let mut pids: Vec<i32> = exception.pids.iter().copied().collect();
            pids.sort_unstable();
            let list = pids
                .iter()
                .map(|pid| pid.to_string())
                .collect::<Vec<_>>()
                .join(", ");
            (self.log)(&format!("pid {list}: {}", exception.text));
        }
        self.inner
            .pause_resolved(outcome, shell_outcome, exceptions, context);
    }
}
