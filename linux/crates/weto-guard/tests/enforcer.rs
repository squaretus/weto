//! Граница применения решения к процессам: пауза, продолжение и учёт.
//!
//! Порт `macos/Tests/WetoSharedTests/ProcessEnforcerTests.swift` в той части,
//! что держит учёт остановленных. Подменяются ровно границы — реестр процессов
//! и сигналы, причём одним и тем же миром: SIGSTOP обязан быть виден следующему
//! обходу. План паузы и сам учёт работают настоящие.

mod harness;

use std::collections::HashSet;
use std::time::{Duration, UNIX_EPOCH};

use harness::{process, FakeSettings, World};
use weto_config::stopped::{StoppedLedger, StoppedProcess};
use weto_core::process::TargetRule;
use weto_guard::enforcer::ProcessEnforcer;
use weto_sys::process_signaler::ProcessSignal::Resume;

const CLAUDE: &str = "/home/me/.local/bin/claude";

/// zsh (100) → claude (200) → node (201): то же дерево переднего задания,
/// на котором проверяется порядок сигналов.
fn terminal_session() -> World {
    World::of(vec![
        process(100, 1, "/usr/bin/zsh", 100, 200),
        process(200, 100, CLAUDE, 200, 200),
        process(201, 200, "/usr/bin/node", 200, 200),
    ])
}

fn rules() -> Vec<TargetRule> {
    FakeSettings::guarding(&[CLAUDE])
        .0
        .lock()
        .unwrap()
        .target_rules()
}

fn stale(pid: i32, path: &str) -> StoppedProcess {
    StoppedProcess {
        pid,
        executable_path: path.to_string(),
        stopped_at: UNIX_EPOCH + Duration::from_secs(999_000),
        is_shell: false,
    }
}

/// Цель, остановленная на переиспользованном pid, обязана доехать до учёта —
/// иначе размораживать её будет некому.
///
/// Учёт, дедуплицировавший по одному pid, свежую запись отбрасывал: «pid уже
/// известен». В учёте оставалось описание мёртвого владельца числа, следующий
/// проход вычёркивал его по несовпадению путей — как исчезнувшего, без SIGCONT, —
/// и цель, которой SIGSTOP уже послан, оставалась стоять навсегда: в учёте её
/// нет, и не увидят её ни такт, ни завершение, ни восстановление на старте.
#[test]
fn a_target_stopped_on_a_recycled_pid_is_recorded_and_later_resumed() {
    let world = terminal_session();
    let home = tempfile::tempdir().expect("временный каталог");
    let path = home.path().join("stopped.json");

    // Учёт помнит мёртвого владельца числа 200: этот pid ядро уже отдало цели.
    let mut previous = StoppedLedger::default();
    previous.add(&[stale(200, "/usr/bin/давно-мёртвый")]);
    previous.save(&path).expect("учёт записался");

    let enforcer = ProcessEnforcer::new(
        Box::new(world.clone()),
        Box::new(world.clone()),
        path.clone(),
    );
    let rules = rules();

    enforcer.pause(&enforcer.scan(&rules));

    assert_eq!(
        StoppedLedger::load(&path)
            .entries()
            .iter()
            .map(|entry| entry.executable_path.as_str())
            .collect::<Vec<_>>(),
        vec!["/usr/bin/zsh", CLAUDE, "/usr/bin/node"],
        "мёртвый владелец pid уступает место остановленной цели"
    );

    // Следующий проход: ядро показывает всех троих стоящими.
    let outcome = enforcer.resume(Some(&enforcer.scan(&rules)), &HashSet::new());

    assert_eq!(
        world.signalled(Resume),
        vec![201, 200, 100],
        "цель на переиспользованном pid обязана получить SIGCONT наравне со всеми"
    );
    assert!(!world.is_stopped(200));
    assert_eq!(
        outcome.unresolved.len(),
        3,
        "обязательство держится до наблюдения: обход снят до сигналов"
    );
    assert_eq!(
        StoppedLedger::load(&path).pids(),
        vec![100, 200, 201],
        "и записи из учёта по отправке сигнала не уходят"
    );
}
