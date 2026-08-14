//! Завершение процессов.
//!
//! Единственное место, где приложение вмешивается в чужую жизнь. Прав root
//! не требует: цели живут в том же uid, что и weto.

use rustix::process::{kill_process, Pid, Signal};

pub trait ProcessKilling: Send + Sync {
    /// Возвращает pid-ы, которым сигнал реально ушёл.
    ///
    /// Список, а не признак успеха: журнал пишет каждый завершённый pid,
    /// а процесс, умерший сам за миг до сигнала, ошибкой не является.
    fn kill(&self, pids: &[i32]) -> Vec<i32>;
}

pub struct SigtermKiller;

impl ProcessKilling for SigtermKiller {
    fn kill(&self, pids: &[i32]) -> Vec<i32> {
        pids.iter()
            .filter(|pid| {
                Pid::from_raw(**pid)
                    .map(|pid| kill_process(pid, Signal::TERM).is_ok())
                    .unwrap_or(false)
            })
            .copied()
            .collect()
    }
}
