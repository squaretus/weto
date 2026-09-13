//! Сигналы процессам.
//!
//! Единственное место, где приложение вмешивается в чужую жизнь. Прав root
//! не требует: цели живут в том же uid, что и weto.
//!
//! Порт `ProcessSignaler` с macOS. Сигналы уходят **строго в порядке списка**:
//! для паузы переднего задания порядок «шелл, затем цель, затем потомки»
//! и обратный при продолжении — часть контракта границы, а не деталь
//! реализации. Шелл, узнавший о стопе цели раньше времени, забирает терминал
//! себе, и цель встаёт по `SIGTTIN` после каждого `SIGCONT`.

use rustix::io::Errno;
use rustix::process::{kill_process, Pid, Signal};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProcessSignal {
    /// Завершение без права на обработчик: потолок паузы и доказательство
    /// утечки завершают именно так — цель не должна успеть ничего. Канон
    /// называет здесь SIGKILL для обеих платформ, и `SIGTERM` граница
    /// не предлагает вовсе: стоящий процесс обработчика не исполняет,
    /// и мягкий сигнал просто встал бы в очередь до продолжения.
    Kill,
    Stop,
    Resume,
}

impl ProcessSignal {
    fn number(self) -> Signal {
        match self {
            ProcessSignal::Kill => Signal::KILL,
            ProcessSignal::Stop => Signal::STOP,
            ProcessSignal::Resume => Signal::CONT,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SignalResult {
    pub pid: i32,
    /// errno неудавшегося `kill(2)`; `None` — сигнал ушёл.
    pub error_code: Option<i32>,
}

impl SignalResult {
    /// Процесс, исчезнувший до сигнала, — не отказ: цель достигнута.
    pub fn is_delivered(&self) -> bool {
        matches!(self.error_code, None | Some(libc::ESRCH))
    }
}

/// Граница, за которой начинается чужая жизнь.
///
/// Результат на каждый pid, а не общий признак успеха: журнал объясняет каждый
/// процесс по отдельности, а учёт остановленных обязан знать, кому сигнал
/// не ушёл вовсе.
pub trait ProcessSignaling: Send + Sync {
    fn send(&self, signal: ProcessSignal, pids: &[i32]) -> Vec<SignalResult>;
}

type KernelSend = Box<dyn Fn(i32, ProcessSignal) -> Option<i32> + Send + Sync>;

pub struct ProcessSignaler {
    send_to_kernel: KernelSend,
}

impl ProcessSignaler {
    pub fn new() -> ProcessSignaler {
        ProcessSignaler {
            send_to_kernel: Box::new(send_to_kernel),
        }
    }

    /// Сейм для собственных тестов границы: позволяет зафиксировать порядок
    /// и содержимое вызовов `kill(2)`, а не только порядок результатов.
    /// Не публичный — всё, что выше этой границы (`ProcessEnforcer` и дальше),
    /// обязано собирать `ProcessSignaler::new()`; подмена самого ядра
    /// для них недоступна и не должна становиться доступной — в сборку
    /// приложения сейм не попадает вовсе.
    #[cfg(test)]
    fn with_kernel(send_to_kernel: KernelSend) -> ProcessSignaler {
        ProcessSignaler { send_to_kernel }
    }
}

impl Default for ProcessSignaler {
    fn default() -> Self {
        Self::new()
    }
}

impl ProcessSignaling for ProcessSignaler {
    fn send(&self, signal: ProcessSignal, pids: &[i32]) -> Vec<SignalResult> {
        pids.iter()
            .map(|pid| SignalResult {
                pid: *pid,
                error_code: (self.send_to_kernel)(*pid, signal),
            })
            .collect()
    }
}

/// `kill(0, …)` в ядре означает «всей своей группе процессов», а `kill(-1, …)` —
/// «всем, кому можем». Ни то, ни другое сюда прийти не должно, и молча
/// расширять сигнал на соседей граница не станет: такой pid — ошибка вызова.
fn send_to_kernel(pid: i32, signal: ProcessSignal) -> Option<i32> {
    // Проверка раньше `Pid::from_raw`, а не вместо неё: на отрицательном
    // значении тот падает по внутреннему `assert`, и «ошибка вызова» стала бы
    // паникой всего приложения.
    if pid <= 0 {
        return Some(Errno::INVAL.raw_os_error());
    }
    let Some(pid) = Pid::from_raw(pid) else {
        return Some(Errno::INVAL.raw_os_error());
    };
    kill_process(pid, signal.number())
        .err()
        .map(|errno| errno.raw_os_error())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    /// Порядок — часть контракта: шелл раньше цели на стопе, цель раньше шелла
    /// на продолжении.
    ///
    /// `results` совпал бы со входным списком при любой реализации, которая
    /// возвращает по результату на pid, — даже при отправке в обратном порядке
    /// или параллельно: `SignalResult` всегда несёт тот pid, для которого он
    /// посчитан, и порядок результатов ничего не говорит о порядке, в котором
    /// сигналы дошли до ядра. Поэтому подменяется сама точка вызова `kill(2)`
    /// и фиксируется порядок фактических вызовов — живые процессы здесь
    /// не нужны вовсе.
    #[test]
    fn signals_reach_the_kernel_in_list_order() {
        let calls = Arc::new(Mutex::new(Vec::new()));
        let recorded = Arc::clone(&calls);
        let signaler = ProcessSignaler::with_kernel(Box::new(move |pid, signal| {
            recorded.lock().unwrap().push((pid, signal));
            None
        }));

        let stopped = signaler.send(ProcessSignal::Stop, &[222, 111, 333]);

        assert_eq!(
            *calls.lock().unwrap(),
            vec![
                (222, ProcessSignal::Stop),
                (111, ProcessSignal::Stop),
                (333, ProcessSignal::Stop),
            ]
        );
        assert!(stopped.iter().all(SignalResult::is_delivered));

        calls.lock().unwrap().clear();
        signaler.send(ProcessSignal::Resume, &[333, 111, 222]);

        assert_eq!(
            *calls.lock().unwrap(),
            vec![
                (333, ProcessSignal::Resume),
                (111, ProcessSignal::Resume),
                (222, ProcessSignal::Resume),
            ]
        );
    }

    /// Номера сигналов — то, ради чего граница существует: перепутанные местами
    /// `STOP` и `CONT` тестом с подменённым ядром не ловятся ничем иным.
    #[test]
    fn every_signal_maps_to_its_kernel_number() {
        assert_eq!(ProcessSignal::Kill.number().as_raw(), libc::SIGKILL);
        assert_eq!(ProcessSignal::Stop.number().as_raw(), libc::SIGSTOP);
        assert_eq!(ProcessSignal::Resume.number().as_raw(), libc::SIGCONT);
    }

    /// Нулевой и отрицательный pid ядро понимает как «группе» и «всем подряд».
    /// Граница обязана отказать, а не расширить сигнал на соседей.
    #[test]
    fn a_group_wide_pid_is_refused_instead_of_being_widened() {
        let results = ProcessSignaler::new().send(ProcessSignal::Stop, &[0, -1]);

        assert_eq!(results.len(), 2);
        assert!(results.iter().all(|result| !result.is_delivered()));
    }
}
