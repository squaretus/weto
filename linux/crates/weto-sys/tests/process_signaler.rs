//! Граница сигналов проверяется на живых процессах.
//!
//! Порядок вызовов пришпилен отдельно, внутри самого модуля: там подменяется
//! точка вызова `kill(2)`, и живые процессы для этого не нужны. Здесь — то,
//! чего подменой не проверить: что SIGSTOP действительно останавливает,
//! SIGCONT снимает, SIGKILL завершает, а исчезнувший процесс считается
//! доставкой.

use std::process::{Child, Command, Stdio};
use std::time::Duration;

use weto_sys::process_registry::{ProcRegistry, ProcessRegistryReading};
use weto_sys::process_signaler::{ProcessSignal, ProcessSignaler, ProcessSignaling, SignalResult};

/// Убирает за собой в любом исходе, включая провалившийся ассерт: SIGCONT
/// раньше — остановленный процесс SIGTERM бы не взял, тот лишь лёг бы
/// в очередь ожидающих.
struct Spawned(Child);

impl Drop for Spawned {
    fn drop(&mut self) {
        unsafe { libc::kill(self.0.id() as i32, libc::SIGCONT) };
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

impl Spawned {
    fn sleeping(seconds: &str) -> Spawned {
        Spawned(
            Command::new("sleep")
                .arg(seconds)
                .stdout(Stdio::null())
                .spawn()
                .unwrap(),
        )
    }

    fn pid(&self) -> i32 {
        self.0.id() as i32
    }
}

fn is_stopped(pid: i32) -> Option<bool> {
    ProcRegistry::new()
        .snapshot()
        .into_iter()
        .find(|process| process.pid == pid)
        .map(|process| process.is_stopped)
}

/// Ядру нужно мгновение, чтобы перевести процесс в `T` и обратно.
fn settles_to(pid: i32, expected: Option<bool>) -> bool {
    for _ in 0..100 {
        if is_stopped(pid) == expected {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    false
}

/// Остановка, продолжение и завершение — то, ради чего граница существует.
/// Наблюдатель здесь независимый: состояние читает реестр из `/proc`,
/// а не наш же возвращённый результат.
#[test]
fn stop_resume_and_kill_are_visible_in_proc() {
    let child = Spawned::sleeping("86410");
    let signaler = ProcessSignaler::new();

    assert_eq!(is_stopped(child.pid()), Some(false));

    let stopped = signaler.send(ProcessSignal::Stop, &[child.pid()]);
    assert!(stopped.iter().all(SignalResult::is_delivered));
    assert!(settles_to(child.pid(), Some(true)), "SIGSTOP останавливает");

    let resumed = signaler.send(ProcessSignal::Resume, &[child.pid()]);
    assert!(resumed.iter().all(SignalResult::is_delivered));
    assert!(
        settles_to(child.pid(), Some(false)),
        "SIGCONT снимает остановку"
    );

    let killed = signaler.send(ProcessSignal::Kill, &[child.pid()]);
    assert!(killed.iter().all(SignalResult::is_delivered));
    assert!(settles_to(child.pid(), None), "SIGKILL завершает");
}

/// Тот сигнал, которым Linux-охрана завершает цели сегодня. Мягкий, и потому
/// проверяется отдельно: обработчик у `sleep` его не перехватывает, но сам
/// факт доставки — не то же самое, что у SIGKILL.
#[test]
fn terminate_ends_the_process_too() {
    let child = Spawned::sleeping("86411");

    let results = ProcessSignaler::new().send(ProcessSignal::Terminate, &[child.pid()]);

    assert!(results.iter().all(SignalResult::is_delivered));
    assert!(settles_to(child.pid(), None), "SIGTERM завершает `sleep`");
}

/// Процесс, умерший до сигнала, — не отказ: цель достигнута, и журнал обязан
/// объяснить его наравне с остальными.
#[test]
fn a_process_that_is_already_gone_counts_as_delivered() {
    let mut child = Command::new("sleep").arg("0").spawn().unwrap();
    let pid = child.id() as i32;
    child.wait().unwrap();
    // Зомби уже пожат `wait`, pid свободен — ядро ответит ESRCH.

    let results = ProcessSignaler::new().send(ProcessSignal::Stop, &[pid]);

    assert_eq!(results.len(), 1);
    assert_eq!(results[0].error_code, Some(libc::ESRCH));
    assert!(results[0].is_delivered());
}

/// Результат на каждый pid, и по своему на каждый: живой, мёртвый и вовсе
/// несуществующий в одном списке не сливаются в общий признак успеха.
#[test]
fn every_pid_gets_its_own_result_in_list_order() {
    let child = Spawned::sleeping("86412");
    let missing = i32::MAX - 7;

    let results = ProcessSignaler::new().send(ProcessSignal::Resume, &[child.pid(), missing]);

    assert_eq!(
        results.iter().map(|result| result.pid).collect::<Vec<_>>(),
        vec![child.pid(), missing]
    );
    assert_eq!(results[0].error_code, None);
    assert_eq!(results[1].error_code, Some(libc::ESRCH));
}
