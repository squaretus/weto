//! Граница применения решения к процессам: пауза, продолжение и учёт.
//!
//! Порт `macos/Tests/WetoSharedTests/ProcessEnforcerTests.swift` в той части,
//! что держит учёт остановленных. Подменяются ровно границы — реестр процессов
//! и сигналы, причём одним и тем же миром: SIGSTOP обязан быть виден следующему
//! обходу. План паузы и сам учёт работают настоящие.

mod harness;

use std::collections::HashSet;
use std::time::{Duration, UNIX_EPOCH};

use harness::{on_terminal, process, FakeSettings, RecordingTerminalModes, World};
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
        target_entry: None,
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

// --- режим терминала ---------------------------------------------------------

/// `tty_nr` первого pty: major 136, minor 3.
const TTY: i32 = (136 << 8) | 3;

/// То же переднее задание, но на настоящем терминале.
fn session_on_terminal() -> World {
    World::of(vec![
        on_terminal(process(100, 1, "/usr/bin/zsh", 100, 200), TTY),
        on_terminal(process(200, 100, CLAUDE, 200, 200), TTY),
        on_terminal(process(201, 200, "/usr/bin/node", 200, 200), TTY),
    ])
}

/// Каталог учёта живёт столько же, сколько граница: учёт пишется настоящим файлом.
fn enforcer_over(
    world: &World,
    modes: &RecordingTerminalModes,
) -> (ProcessEnforcer, tempfile::TempDir) {
    let home = tempfile::tempdir().expect("временный каталог");
    let enforcer = ProcessEnforcer::new(
        Box::new(world.clone()),
        Box::new(world.clone()),
        home.path().join("stopped.json"),
    )
    .with_terminal_modes(Box::new(modes.clone()));
    (enforcer, home)
}

/// Под tmux шелл остановленным не удержать: tmux продолжает его сразу, шелл замечает
/// SIGSTOP своего задания, забирает терминал и переключает его режим; `claude` сама
/// сырой режим не восстанавливает, и после `fg` клавиши до неё не доходили. Режим
/// снимается до остановки и возвращается ровно один раз — когда цель снова идёт
/// и снова впереди: пауза кончилась, пользователь ввёл `fg`.
#[test]
fn the_terminal_mode_of_a_foreground_target_comes_back_once_it_is_in_front_again() {
    let world = session_on_terminal();
    let modes = RecordingTerminalModes::default();
    let (enforcer, _home) = enforcer_over(&world, &modes);
    let rules = rules();

    enforcer.pause(&enforcer.scan(&rules));
    assert_eq!(
        modes.captured(),
        vec![TTY],
        "режим снят до SIGSTOP — пока он ещё сырой"
    );

    // Пауза: tmux продолжил шелл, и тот забрал терминал. Возвращать режим некому и незачем.
    world.continues(100);
    world.terminal_goes_to(100);
    enforcer.restore_terminal_modes(Some(&enforcer.scan(&rules)));
    assert!(modes.restored().is_empty(), "под паузой режим не трогаем");

    // Пауза кончилась: SIGCONT ушёл, цель идёт, но фоном — терминал у шелла.
    enforcer.resume(Some(&enforcer.scan(&rules)), &HashSet::new());
    enforcer.resume(Some(&enforcer.scan(&rules)), &HashSet::new());
    assert!(
        enforcer.ledger_is_empty(),
        "учёт отпустил всех по наблюдению"
    );
    enforcer.restore_terminal_modes(Some(&enforcer.scan(&rules)));
    assert!(
        modes.restored().is_empty(),
        "цель фоном — режим шелла её не касается, пока не `fg`"
    );

    // `fg`: терминал снова у цели.
    world.terminal_goes_to(200);
    enforcer.restore_terminal_modes(Some(&enforcer.scan(&rules)));
    assert_eq!(modes.restored(), vec![TTY], "сырой режим вернулся");

    enforcer.restore_terminal_modes(Some(&enforcer.scan(&rules)));
    assert_eq!(
        modes.restored().len(),
        1,
        "ровно один раз: дальше режимом правит сама программа"
    );
}

/// Фоновое задание терминала не держит — и снимать с него режим нечего: режим
/// терминала принадлежит тому, кто впереди.
#[test]
fn a_background_target_leaves_the_terminal_mode_alone() {
    let world = World::of(vec![
        on_terminal(process(100, 1, "/usr/bin/zsh", 100, 100), TTY),
        on_terminal(process(200, 100, CLAUDE, 200, 100), TTY),
    ]);
    let modes = RecordingTerminalModes::default();
    let (enforcer, _home) = enforcer_over(&world, &modes);

    enforcer.pause(&enforcer.scan(&rules()));

    assert_eq!(
        world.signalled(weto_sys::process_signaler::ProcessSignal::Stop),
        vec![200]
    );
    assert!(modes.captured().is_empty());
}

/// Цель умерла, пока стояла, и её pid достался другому процессу на том же терминале:
/// чужому процессу режим не навязываем — ни сразу, ни потом.
#[test]
fn a_target_that_is_gone_takes_its_terminal_mode_with_it() {
    let world = session_on_terminal();
    let modes = RecordingTerminalModes::default();
    let (enforcer, _home) = enforcer_over(&world, &modes);
    let rules = rules();
    enforcer.pause(&enforcer.scan(&rules));
    assert_eq!(modes.captured(), vec![TTY]);

    world.remove(201);
    world.remove(200);
    world.continues(100);
    world.add(on_terminal(
        process(200, 100, "/usr/bin/vim", 200, 200),
        TTY,
    ));
    enforcer.resume(Some(&enforcer.scan(&rules)), &HashSet::new());
    enforcer.restore_terminal_modes(Some(&enforcer.scan(&rules)));
    assert!(
        modes.restored().is_empty(),
        "чужому процессу на том же pid режим не навязываем"
    );

    // И забыт режим насовсем: вернись по тому же pid тот же путь — это уже
    // другой сеанс, и сырой режим прошлого ему не принадлежит.
    world.remove(200);
    world.add(on_terminal(process(200, 100, CLAUDE, 200, 200), TTY));
    enforcer.restore_terminal_modes(Some(&enforcer.scan(&rules)));
    assert!(modes.restored().is_empty());
}
