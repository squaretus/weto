//! Пауза: сигналы, обязательство и журнал стояния.
//!
//! Подменяются ровно границы — реестр процессов, сигналы, сеть, гео, часы.
//! План паузы, редьюсер, политика и учёт остановленных работают настоящие:
//! проверять «обязательство снимает наблюдение» на выдуманном учёте
//! бессмысленно.

mod harness;

use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use harness::{build, build_with_broken_ledger, detached, process, FakeSettings, Harness, World};
use weto_config::stopped::{StoppedLedger, StoppedProcess};
use weto_core::check::{CheckOutcome, CheckTrigger};
use weto_core::guard_machine::{GuardAction, GuardPhase};
use weto_core::policy::UnsafeEvidence;
use weto_core::process::{MatchBasis, ProcessSnapshot};
use weto_sys::process_signaler::ProcessSignal::{Kill, Resume, Stop};

const CLAUDE: &str = "/home/me/.local/bin/claude";

/// zsh (100, своя группа, терминал в переднем плане у группы 200)
/// → claude (200, лидер группы 200) → node (201, потомок в той же группе).
/// Рядом — живой VPN-клиент, без него до гео дело не дойдёт.
fn terminal_session() -> Vec<ProcessSnapshot> {
    vec![
        process(100, 1, "/usr/bin/zsh", 100, 200),
        process(200, 100, CLAUDE, 200, 200),
        process(201, 200, "/usr/bin/node", 200, 200),
        detached(77, 1, "/usr/bin/happ"),
    ]
}

/// Переводимые часы: потолок паузы проверяется переводом стрелок, а не минутой
/// ожидания.
#[derive(Clone)]
struct Hands(Arc<Mutex<SystemTime>>);

impl Hands {
    fn new() -> Hands {
        Hands(Arc::new(Mutex::new(
            UNIX_EPOCH + Duration::from_secs(1_000_000),
        )))
    }

    fn advance(&self, seconds: u64) {
        let mut now = self.0.lock().unwrap();
        *now += Duration::from_secs(seconds);
    }
}

struct Stand {
    h: Harness,
    hands: Hands,
}

impl std::ops::Deref for Stand {
    type Target = Harness;
    fn deref(&self) -> &Harness {
        &self.h
    }
}

fn stand_with(world: World, ledger: &[StoppedProcess]) -> Stand {
    let hands = Hands::new();
    let moving = hands.clone();
    let mut h = build(
        Duration::ZERO,
        FakeSettings::guarding(&[CLAUDE]),
        world,
        ledger,
    );
    h.controller = h
        .controller
        .with_clock(Box::new(move || *moving.0.lock().unwrap()));
    Stand { h, hands }
}

fn stand() -> Stand {
    stand_with(World::of(terminal_session()), &[])
}

/// Довести охрану до «На страже»: первый такт спрашивает и получает ответ.
fn guarded(stand: &Stand) {
    let phase = stand.controller.tick();
    assert!(matches!(phase, GuardPhase::Protected(_)), "{phase:?}");
    assert!(stand.world.signals().is_empty());
}

/// Сервисы замолчали, и охрана это узнала: первый же такой ответ — пауза.
fn services_go_silent(stand: &Stand) -> GuardPhase {
    stand.geo.everything_goes_silent();
    stand.controller.probe_now()
}

fn ledger_pids(stand: &Stand) -> Vec<i32> {
    StoppedLedger::load(&stand.ledger_path).pids()
}

// --- пауза и её снятие ------------------------------------------------------

/// Плохой результат ставит цели на паузу, хороший — снимает. Ни то, ни другое
/// не делает ничего третьего: цели не завершаются.
#[test]
fn a_bad_result_pauses_and_a_good_one_resumes() {
    let s = stand();
    guarded(&s);

    let paused = services_go_silent(&s);
    assert_eq!(paused.action(), GuardAction::Pause, "{paused:?}");
    assert_eq!(s.world.signalled(Stop), vec![100, 200, 201]);
    assert!(s.world.is_stopped(200));
    assert!(s.world.signalled(Kill).is_empty(), "пауза — не завершение");

    s.geo.everything_answers_again();
    let running = s.controller.probe_now();
    assert!(matches!(running, GuardPhase::Protected(_)), "{running:?}");
    assert_eq!(s.world.signalled(Resume), vec![201, 200, 100]);
    assert!(!s.world.is_stopped(200));

    // Обязательство снимает наблюдение: проход, отправивший сигнал, видел цели
    // ещё стоящими, и закрывает эпизод следующий.
    assert!(s.reporter.resolutions().is_empty());
    s.controller.tick();
    assert_eq!(
        s.reporter.resolutions(),
        vec!["возобновлено: проверка подтвердила безопасный выход: 203.0.113.7, NL".to_string()]
    );
    assert!(ledger_pids(&s).is_empty(), "учёт опустел по наблюдению");
}

/// Порядок сигналов — часть контракта границы: стоп — шелл, цель, потомки;
/// продолжение — строго наоборот. Тест обязан падать от перестановки двух
/// соседних записей, поэтому сравниваются списки целиком.
#[test]
fn the_signal_order_is_shell_then_target_then_descendants() {
    let s = stand();
    guarded(&s);
    services_go_silent(&s);

    assert_eq!(
        s.world.signals(),
        vec![(Stop, 100), (Stop, 200), (Stop, 201)],
        "шелл узнаёт о стопе раньше цели, иначе он заберёт терминал себе"
    );

    s.world.forget_signals();
    s.geo.everything_answers_again();
    s.controller.probe_now();

    assert_eq!(
        s.world.signals(),
        vec![(Resume, 201), (Resume, 200), (Resume, 100)],
        "продолжение идёт снизу вверх: шелл последним"
    );
}

/// Процесс, остановленный пользователем до нас (`Ctrl-Z`), не трогает ни один
/// план: ни при паузе, ни при продолжении.
#[test]
fn a_process_the_user_stopped_is_touched_by_neither_plan() {
    let mut world = terminal_session();
    // Второй сеанс той же цели: пользователь сам нажал Ctrl-Z.
    world.push(ProcessSnapshot {
        is_stopped: true,
        ..process(300, 1, CLAUDE, 300, 0)
    });
    let s = stand_with(World::of(world), &[]);
    guarded(&s);

    services_go_silent(&s);
    assert!(
        !s.world.signals().iter().any(|(_, pid)| *pid == 300),
        "стоявшему до нас не посылают ничего: {:?}",
        s.world.signals()
    );
    assert!(!ledger_pids(&s).contains(&300), "и в учёт он не попадает");

    s.geo.everything_answers_again();
    s.controller.probe_now();
    s.controller.tick();
    assert!(
        !s.world.signals().iter().any(|(_, pid)| *pid == 300),
        "и на продолжении тоже: {:?}",
        s.world.signals()
    );
    assert!(s.world.is_stopped(300), "он как стоял, так и стоит");
}

// --- потолок ----------------------------------------------------------------

/// Подтверждения нет минуту — цели завершаются, и улика называет ровно это.
#[test]
fn the_ceiling_terminates_what_the_pause_could_not_confirm() {
    let s = stand();
    guarded(&s);
    services_go_silent(&s);

    s.hands.advance(59);
    let still_paused = s.controller.tick();
    assert_eq!(still_paused.action(), GuardAction::Pause);
    assert!(s.world.signalled(Kill).is_empty());

    s.hands.advance(2);
    let expired = s.controller.tick();

    assert_eq!(
        expired,
        GuardPhase::Danger(UnsafeEvidence::PauseExpired),
        "потолок — это доказательство, а не ещё одна пауза"
    );
    assert_eq!(s.world.signalled(Kill), vec![200, 201]);
    assert!(!s.world.is_alive(200));
    assert!(
        s.reporter
            .resolutions()
            .iter()
            .any(|text| text.contains("завершено по потолку")),
        "{:?}",
        s.reporter.resolutions()
    );
}

/// Потерю вердикта под паузой объявляют каждый такт, и отсчёт от неё
/// не перезапускается: иначе минуту можно было бы продлевать вечно сменами пути.
#[test]
fn a_repeated_staleness_announcement_does_not_restart_the_ceiling() {
    let s = stand();
    guarded(&s);
    services_go_silent(&s);

    for step in 0..6 {
        s.hands.advance(10);
        // Каждый раз новый путь наружу: вердикта про него нет, и такт объявляет
        // потерю заново.
        s.network.route_moves_to(&format!("wg{step}"));
        s.controller.tick();
    }

    assert_eq!(
        s.controller.phase(),
        GuardPhase::Danger(UnsafeEvidence::PauseExpired),
        "потолок считается от плохого результата, а не от последней новости"
    );
}

// --- обязательство ----------------------------------------------------------

/// Фоновое задание отвечает стопом на каждый SIGCONT: обязательство держится
/// до наблюдения, досылки ограничены, запись из учёта не уходит, а журнал
/// говорит правду вместо «возобновлено».
#[test]
fn the_obligation_is_held_until_the_kernel_shows_the_process_running() {
    // Цель в фоне: терминал у шелла, и в план паузы шелл не входит.
    let world = World::of(vec![
        process(100, 1, "/usr/bin/zsh", 100, 100),
        process(200, 100, CLAUDE, 200, 100),
        detached(77, 1, "/usr/bin/happ"),
    ]);
    let s = stand_with(world, &[]);
    guarded(&s);

    services_go_silent(&s);
    assert_eq!(s.world.signalled(Stop), vec![200], "шелл не при делах");

    // Задание фоновое: SIGCONT его будит, а tty тут же возвращает в стоп.
    s.world.is_background_job(200);
    s.geo.everything_answers_again();
    s.controller.probe_now();
    for _ in 0..10 {
        s.controller.tick();
    }

    assert_eq!(
        s.world.signalled(Resume).len(),
        1 + 3,
        "первая отправка плюс три ответа — дальше это уже не попытка \
         возобновления, а `suspended (tty input)` раз в секунду"
    );
    assert_eq!(
        ledger_pids(&s),
        vec![200],
        "обязательство остаётся: запись из учёта не уходит"
    );
    assert!(
        s.reporter
            .resolutions()
            .iter()
            .all(|text| !text.starts_with("возобновлено")),
        "«возобновлено» пишется только про наблюдённое возобновление: {:?}",
        s.reporter.resolutions()
    );
    assert!(
        s.reporter
            .resolutions()
            .iter()
            .any(|text| text.contains("не возобновлено: процессы [200]")
                && text.contains("командой fg")),
        "{:?}",
        s.reporter.resolutions()
    );

    // Пользователь ввёл `fg` — и обязательство исполнено наблюдением,
    // а не нашей отправкой.
    s.world.brought_to_foreground(200);
    s.controller.tick();
    assert!(ledger_pids(&s).is_empty());
}

/// Терминальная цель, стоявшая на переднем плане, а после несостоявшегося
/// возобновления потерявшая терминал, уведомляет об этом ровно один раз —
/// не на каждый такт, пока обязательство держится. Порт macOS
/// `GuardVM.surfaceStanding` → `notifyBackgrounded`.
#[test]
fn a_target_that_loses_its_terminal_is_announced_once() {
    let s = stand();
    guarded(&s);

    services_go_silent(&s);
    assert!(
        s.reporter.recorded().backgrounded.is_empty(),
        "стоит на переднем плане, фон ещё не наблюдён"
    );

    // Задание фоновое: SIGCONT его будит, а tty тут же возвращает в стоп.
    s.world.is_background_job(200);
    s.geo.everything_answers_again();
    s.controller.probe_now();
    for _ in 0..5 {
        s.controller.tick();
    }

    assert_eq!(
        s.reporter.recorded().backgrounded,
        vec!["claude".to_string()]
    );
}

/// Цель, чью переднюю группу держит чужое задание, уходит в фон уже в момент
/// паузы, а не только после несостоявшегося возобновления — план это знает
/// сразу (`pause_plan::plan`), и уведомление обязано прийти тем же проходом.
#[test]
fn a_target_paused_while_already_backgrounded_is_announced_immediately() {
    let world = World::of(vec![
        process(100, 1, "/usr/bin/zsh", 100, 500),
        process(200, 100, CLAUDE, 200, 500),
        process(500, 100, "/usr/bin/vim", 500, 500),
        detached(77, 1, "/usr/bin/happ"),
    ]);
    let s = stand_with(world, &[]);
    guarded(&s);

    services_go_silent(&s);

    assert_eq!(
        s.reporter.recorded().backgrounded,
        vec!["claude".to_string()]
    );
}

/// Отказ ядра — не наблюдение: журнал называет отказ, а запись остаётся в учёте.
#[test]
fn a_refused_resume_is_named_as_a_refusal() {
    let s = stand();
    guarded(&s);
    services_go_silent(&s);

    s.world.refuses(200);
    s.geo.everything_answers_again();
    s.controller.probe_now();
    s.controller.tick();

    assert!(
        s.reporter
            .resolutions()
            .iter()
            .any(|text| text.contains("не возобновлено: сигнал продолжения не дошёл")),
        "{:?}",
        s.reporter.resolutions()
    );
    assert!(ledger_pids(&s).contains(&200));
}

// --- журнал стояния ---------------------------------------------------------

/// Объяснён обязан быть каждый посланный SIGSTOP — и цель, и её потомок,
/// и шелл, вошедший в план ради терминала.
#[test]
fn every_pid_that_received_a_stop_has_a_record_in_that_episode() {
    let s = stand();
    guarded(&s);
    services_go_silent(&s);

    let mut stopped = s.world.signalled(Stop);
    let mut recorded = s.reporter.paused_pids();
    stopped.sort_unstable();
    recorded.sort_unstable();
    assert_eq!(stopped, recorded);

    let recorded = s.reporter.recorded();
    let shell = recorded
        .paused
        .iter()
        .find(|entry| entry.pid == 100)
        .expect("шелл обязан быть объяснён");
    assert_eq!(shell.matched_by, MatchBasis::Shell);
    assert_eq!(
        shell.target_name, "claude",
        "запись шелла обязана назвать цель, ради терминала которой он встал"
    );
    assert!(recorded
        .paused
        .iter()
        .all(|entry| entry.reason == "Не удалось определить внешний адрес: таймаут запроса"));
}

/// Второй такт под паузой новых записей не заводит: остановлен процесс один раз.
#[test]
fn a_standing_target_is_recorded_once_per_episode() {
    let s = stand();
    guarded(&s);
    services_go_silent(&s);
    let after_first = s.reporter.paused_pids();

    for _ in 0..5 {
        s.controller.tick();
    }

    assert_eq!(s.reporter.paused_pids(), after_first);
}

/// Цель завершена по доказательству, а шелл — продолжен: под общим «завершено»
/// его запись лгала бы, он жив.
#[test]
fn a_shell_released_while_its_target_is_killed_gets_an_honest_outcome() {
    let s = stand();
    guarded(&s);
    services_go_silent(&s);

    s.world.vpn_app_closes();
    let phase = s.controller.tick();

    assert_eq!(phase, GuardPhase::Danger(UnsafeEvidence::VpnAppNotRunning));
    assert_eq!(s.world.signalled(Kill), vec![200, 201]);
    assert!(
        s.world.signalled(Resume).contains(&100),
        "шеллу возвращают терминал, а не убивают его: {:?}",
        s.world.signals()
    );

    let recorded = s.reporter.recorded();
    assert_eq!(
        recorded.resolutions,
        vec![(
            "завершено по доказательству: VPN-приложение не запущено".to_string(),
            Some(
                "продолжен: цель завершена по доказательству: VPN-приложение не запущено"
                    .to_string()
            )
        )]
    );
    assert_eq!(
        recorded.killed,
        vec![200, 201],
        "новость «цели завершены» не исчезает оттого, что цель перед смертью стояла"
    );
    assert!(
        recorded.recordable.is_empty(),
        "но записи про те же pid второй раз не бывает: эпизод паузы их уже описал"
    );
}

// --- восстановление после падения -------------------------------------------

fn standing_entry(pid: i32, path: &str, is_shell: bool) -> StoppedProcess {
    StoppedProcess {
        pid,
        executable_path: path.to_string(),
        stopped_at: UNIX_EPOCH + Duration::from_secs(999_000),
        is_shell,
    }
}

/// Учёт пережил падение weto: стоящие процессы получают SIGCONT, остаются
/// видимыми и получают собственный эпизод журнала — пробы за их стоянием нет,
/// и текст говорит это прямо.
#[test]
fn processes_found_standing_at_startup_are_resumed_and_explained() {
    let world = World::of(vec![
        ProcessSnapshot {
            is_stopped: true,
            ..process(100, 1, "/usr/bin/zsh", 100, 200)
        },
        ProcessSnapshot {
            is_stopped: true,
            ..process(200, 100, CLAUDE, 200, 200)
        },
        detached(77, 1, "/usr/bin/happ"),
    ]);
    // Порядок учёта — порядок отправки SIGSTOP: шелл первым.
    let s = stand_with(
        world,
        &[
            standing_entry(100, "/usr/bin/zsh", true),
            standing_entry(200, CLAUDE, false),
        ],
    );

    s.controller.recover_stopped();

    assert_eq!(
        s.world.signalled(Resume),
        vec![200, 100],
        "порядок продолжения — точный обратный стоп-порядку, и он доехал учётом"
    );

    let recorded = s.reporter.recorded();
    assert_eq!(recorded.recovered.len(), 2);
    assert!(recorded.recovered.iter().all(|entry| entry.reason
        == "Найдены остановленными от прошлого запуска weto: пробы за этим стоянием нет"));
    assert_eq!(
        recorded
            .recovered
            .iter()
            .find(|entry| entry.pid == 100)
            .map(|entry| entry.matched_by),
        Some(MatchBasis::Shell),
        "шеллом запись сделал учёт, а не текущий разбор"
    );
    drop(recorded);

    let event = s
        .checks
        .events()
        .into_iter()
        .find(|event| event.trigger == CheckTrigger::StartupRecovery)
        .expect("восстановление обязано оставить след");
    assert_eq!(event.outcome, CheckOutcome::StandingProcessesRemain);

    // Пилюля стоящей цели видна сразу; шелл целью не становится.
    let paused = s.controller.snapshot().paused;
    assert_eq!(paused.len(), 1);
    assert_eq!(paused[0].pid, 200);
    assert_eq!(paused[0].since, UNIX_EPOCH + Duration::from_secs(999_000));
}

/// pid переиспользуются: по тому же числу может жить уже другой процесс,
/// и SIGCONT ему недопустим.
#[test]
fn a_reused_pid_is_not_resumed() {
    let world = World::of(vec![
        ProcessSnapshot {
            is_stopped: true,
            ..process(200, 1, "/usr/bin/sleep", 200, 0)
        },
        detached(77, 1, "/usr/bin/happ"),
    ]);
    let s = stand_with(world, &[standing_entry(200, CLAUDE, false)]);

    s.controller.recover_stopped();

    assert!(
        s.world.signals().is_empty(),
        "чужому процессу по тому же pid сигнала не шлют: {:?}",
        s.world.signals()
    );
    assert!(ledger_pids(&s).is_empty(), "а запись из учёта уходит");
}

/// Испорченный учёт запуск не блокирует, но молчать о нём нельзя: обязательство
/// «вернуть SIGCONT» в этот запуск выполнено не было, и пустое чтение иначе
/// неотличимо от «возобновлять нечего».
#[test]
fn an_unreadable_ledger_leaves_a_trace() {
    let broken = build_with_broken_ledger(
        FakeSettings::guarding(&[CLAUDE]),
        World::of(terminal_session()),
    );

    broken.controller.recover_stopped();

    let event = broken
        .checks
        .events()
        .into_iter()
        .find(|event| event.outcome == CheckOutcome::LedgerUnreadable)
        .expect("непрочитанный учёт обязан оставить след");
    assert_eq!(event.trigger, CheckTrigger::StartupRecovery);
}

// --- штатный выход ----------------------------------------------------------

/// Штатный выход замороженных целей не оставляет — но и «возобновлено» не пишет:
/// наблюдать последствия сигнала уже нечем.
#[test]
fn shutdown_resumes_and_admits_it_cannot_observe_the_result() {
    let s = stand();
    guarded(&s);
    services_go_silent(&s);

    s.controller.shutdown();

    assert_eq!(s.world.signalled(Resume), vec![201, 200, 100]);
    let resolutions = s.reporter.resolutions();
    assert_eq!(resolutions.len(), 1);
    assert!(
        resolutions[0].starts_with("не подтверждено: сигнал продолжения отправлен процессам")
            && resolutions[0].contains("при следующем запуске"),
        "{resolutions:?}"
    );
    assert_eq!(s.controller.phase(), GuardPhase::Disabled);
}

/// Сигнал не проходит — и выход обязан назвать отказ, а не тишину.
#[test]
fn shutdown_names_a_refusal_instead_of_silence() {
    let s = stand();
    guarded(&s);
    services_go_silent(&s);
    s.world.refuses(200);

    s.controller.shutdown();

    assert!(
        s.reporter.resolutions()[0].contains("не возобновлено: сигнал продолжения не дошёл"),
        "{:?}",
        s.reporter.resolutions()
    );
}
