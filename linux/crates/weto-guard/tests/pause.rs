//! Пауза: сигналы, обязательство и журнал стояния.
//!
//! Подменяются ровно границы — реестр процессов, сигналы, сеть, гео, часы.
//! План паузы, редьюсер, политика и учёт остановленных работают настоящие:
//! проверять «обязательство снимает наблюдение» на выдуманном учёте
//! бессмысленно.

mod harness;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use harness::{
    build, build_with_broken_ledger, build_with_signaler, detached, process, FakeSettings, Harness,
    World,
};
use weto_config::stopped::{StoppedLedger, StoppedProcess};
use weto_core::check::{CheckOutcome, CheckTrigger};
use weto_core::guard_machine::{GuardAction, GuardPhase};
use weto_core::policy::UnsafeEvidence;
use weto_core::process::{MatchBasis, ProcessSnapshot};
use weto_sys::process_signaler::ProcessSignal::{Kill, Resume, Stop};
use weto_sys::process_signaler::{ProcessSignal, ProcessSignaling, SignalResult};

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
    stand_guarding(&[CLAUDE], world, ledger)
}

fn stand_guarding(paths: &[&str], world: World, ledger: &[StoppedProcess]) -> Stand {
    let hands = Hands::new();
    let moving = hands.clone();
    let mut h = build(Duration::ZERO, FakeSettings::guarding(paths), world, ledger);
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

/// Проход, у которого сошлись незакрытое обязательство и ответ пробы, шлёт
/// SIGCONT одной партией.
///
/// Обязательство снимает наблюдение, и цель, ответившая стопом на собственный
/// SIGCONT, получает сигнал снова — следующим проходом, а не дважды в этом.
/// Вторая отправка внутри одного прохода тратила бы вдвое быстрее и лимит
/// досылок (`RESUME_RETRY_LIMIT`), и терпение пользователя: `notify` у zsh
/// печатает `suspended (tty input)` на каждую.
#[test]
fn one_pass_sends_one_batch_of_resumes() {
    let s = stand();
    guarded(&s);
    services_go_silent(&s);
    assert_eq!(s.world.signalled(Stop), vec![100, 200, 201]);

    // Цель — фоновое задание: SIGCONT её будит, а tty тут же возвращает в стоп,
    // и учёт её не отпускает. Ровно поэтому на следующем проходе обязательство
    // ещё живо, а проба к тому времени успевает ответить.
    s.world.is_background_job(200);
    s.geo.everything_answers_again();
    s.controller.probe_now();

    s.world.forget_signals();
    s.controller.probe_now();

    assert_eq!(
        s.world.signalled(Resume),
        vec![201, 200, 100],
        "входов у прохода бывает несколько, применение — одно: {:?}",
        s.world.signals()
    );
}

// --- рождённые под красным статусом ------------------------------------------

/// Цель, запущенная, когда охрана уже стоит, обязана встать наравне с остальными.
///
/// Её запуск не меняет фазу, а значит не приносит и перехода — применяться
/// обязано действие текущей фазы, каждый такт. Живого системного события про
/// запуск терминального процесса не существует, ловить её больше нечем, и ровно
/// за этим под красным статусом такт учащается до 250 мс. Порт macOS
/// `GuardVM.applyCurrentAction`.
#[test]
fn a_target_born_under_the_pause_is_stopped_by_the_next_tick() {
    let s = stand();
    guarded(&s);
    services_go_silent(&s);
    assert_eq!(s.world.signalled(Stop), vec![100, 200, 201]);

    // Второй терминал: пользователь запустил claude, пока цели стоят.
    s.world.add(process(300, 1, "/usr/bin/zsh", 300, 400));
    s.world.add(process(400, 300, CLAUDE, 400, 400));

    let phase = s.controller.tick();

    assert_eq!(phase.action(), GuardAction::Pause, "{phase:?}");
    assert_eq!(
        s.world.signalled(Stop),
        vec![100, 200, 201, 300, 400],
        "порядок «шелл, потом цель» держится и у новорождённой: {:?}",
        s.world.signals()
    );
    assert!(s.world.is_stopped(400));
    assert_eq!(
        ledger_pids(&s),
        vec![100, 200, 201, 300, 400],
        "обязательство «вернуть из паузы» распространяется и на новорождённую"
    );

    // Записи новорождённой — в том же эпизоде и с его причиной: свой текст
    // она не приносит, а про уже описанные pid второй записи не бывает.
    let recorded = s.reporter.recorded();
    let mut pids: Vec<i32> = recorded.paused.iter().map(|entry| entry.pid).collect();
    pids.sort_unstable();
    assert_eq!(pids, vec![100, 200, 201, 300, 400]);
    assert!(
        recorded
            .paused
            .iter()
            .all(|entry| entry.reason == "Не удалось определить внешний адрес: таймаут запроса"),
        "{:?}",
        recorded.paused
    );
    let newcomer = recorded
        .paused
        .iter()
        .find(|entry| entry.pid == 400)
        .expect("новорождённая цель обязана быть объяснена");
    assert_eq!(newcomer.matched_by, MatchBasis::Rule);
    assert_eq!(newcomer.target_name, "claude");
    let shell = recorded
        .paused
        .iter()
        .find(|entry| entry.pid == 300)
        .expect("шелл новорождённой обязан быть объяснён");
    assert_eq!(shell.matched_by, MatchBasis::Shell);
    assert_eq!(shell.target_name, "claude");
    drop(recorded);

    // И снятие паузы у неё общее с остальными: обратный порядок внутри
    // собственного плана — цель, потом её шелл.
    s.geo.everything_answers_again();
    s.controller.probe_now();
    assert_eq!(s.world.signalled(Resume), vec![400, 300, 201, 200, 100]);
}

/// Под «Опасно» запуск целей запрещён, и запрет держится не одним переходом:
/// цель, запущенная заново, завершается следующим же тактом и получает свою
/// запись журнала с той же причиной.
#[test]
fn a_target_relaunched_under_danger_is_killed_by_the_next_tick() {
    let s = stand();
    guarded(&s);

    s.geo.now_reports("RU");
    let danger = s.controller.probe_now();
    assert!(matches!(danger, GuardPhase::Danger(_)), "{danger:?}");
    assert_eq!(s.world.signalled(Kill), vec![200, 201]);

    // Пользователь запустил claude заново, пока статус красный.
    s.world.add(process(400, 100, CLAUDE, 400, 400));

    let phase = s.controller.tick();

    assert_eq!(phase.action(), GuardAction::Terminate, "{phase:?}");
    assert_eq!(s.world.signalled(Kill), vec![200, 201, 400]);
    assert!(!s.world.is_alive(400));

    let recorded = s.reporter.recorded();
    assert_eq!(recorded.killed, vec![200, 201, 400]);
    assert_eq!(
        recorded.recordable,
        vec![200, 201, 400],
        "у запущенной под запретом цели своя запись, а старые не задваиваются"
    );
    assert!(
        recorded
            .kill_reasons
            .iter()
            .all(|reason| reason.contains("RU")),
        "{:?}",
        recorded.kill_reasons
    );
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

// --- снятие цели с охраны под паузой -----------------------------------------

const NANO: &str = "/usr/bin/nano";

/// Цель, снятую с охраны под паузой, weto обязан отпустить тем же тактом.
/// Пилюля у неё исчезала сразу, а SIGCONT не уходил вовсе: процесс стоял
/// до исхода эпизода — то есть до минуты потолка, — уже после того, как
/// пользователь сказал «это больше не моё».
#[test]
fn a_target_removed_from_the_guard_while_standing_is_released_at_once() {
    let mut world = terminal_session();
    world.push(detached(300, 1, NANO));
    let s = stand_guarding(&[CLAUDE, NANO], World::of(world), &[]);
    guarded(&s);
    services_go_silent(&s);

    assert_eq!(s.world.signalled(Stop), vec![100, 300, 200, 201]);
    assert_eq!(ledger_pids(&s), vec![100, 300, 200, 201]);
    let mut standing: Vec<i32> = s
        .controller
        .snapshot()
        .paused
        .iter()
        .map(|p| p.pid)
        .collect();
    standing.sort_unstable();
    assert_eq!(standing, vec![200, 300], "стоят обе цели");

    // Пользователь снимает с охраны одну цель: сигнал ей уходит тем же тактом,
    // а не исходом эпизода.
    s.world.forget_signals();
    s.settings
        .edit(|settings| settings.targets.retain(|target| target.entry != NANO));
    s.controller.tick();

    assert_eq!(
        s.world.signalled(Resume),
        vec![300],
        "продолжение — только снятой цели: чужой терминал не трогаем. И ровно одно: \
         входов у такта бывает несколько, применение — одно"
    );
    assert!(!s.world.is_stopped(300), "снятая с охраны цель пошла");
    assert!(s.world.is_stopped(200), "оставшаяся цель по-прежнему стоит");
    assert!(s.world.is_stopped(100), "и её шелл тоже");
    assert_eq!(
        ledger_pids(&s),
        vec![100, 300, 200, 201],
        "обязательство снимает наблюдение: проход, отправивший сигнал, видел \
         процесс ещё стоящим"
    );
    assert_eq!(
        s.controller
            .snapshot()
            .paused
            .iter()
            .map(|p| p.pid)
            .collect::<Vec<i32>>(),
        vec![200],
        "пилюля снятой цели исчезла, а чужая осталась"
    );
    assert_eq!(
        s.controller.phase().action(),
        GuardAction::Pause,
        "эпизод продолжается"
    );
    assert!(
        s.reporter.resolutions().is_empty(),
        "исход эпизода ещё не наступил"
    );

    assert_eq!(
        s.reporter.recorded().released,
        vec![(
            vec![300],
            "не подтверждено: цель снята с охраны, продолжение отправлено — \
             результат ещё не наблюдался"
                .to_string()
        )],
        "журнал говорит установленное: сигнал отправлен, результат не наблюдался"
    );

    // Следующий проход видит процесс идущим — и только тогда запись уходит
    // из учёта, а журнал дописывает наблюдённое.
    s.controller.tick();
    assert_eq!(
        s.world.signalled(Resume),
        vec![300, 300],
        "пока обязательство держится, сигнал досылается — по одному на проход"
    );
    assert_eq!(
        ledger_pids(&s),
        vec![100, 200, 201],
        "запись уходит из учёта по наблюдению, а не по отправке сигнала"
    );
    assert_eq!(
        s.reporter.recorded().released.last().cloned(),
        Some((vec![300], "продолжен: цель снята с охраны".to_string())),
        "наблюдение дописывает исход — и не переписывает чужой"
    );
    assert!(
        s.reporter.resolutions().is_empty(),
        "исход эпизода по-прежнему не наступил"
    );

    // Эпизод кончился безопасным выходом: исход достаётся оставшимся записям.
    s.geo.everything_answers_again();
    s.controller.probe_now();
    s.controller.tick();
    assert_eq!(
        s.reporter.resolutions(),
        vec!["возобновлено: проверка подтвердила безопасный выход: 203.0.113.7, NL".to_string()]
    );
}

/// Шелл — не цель: он стоит ради терминала цели, с которой его взяли, и отпустить
/// его раньше неё значит отдать ей терминал обратно и получить SIGTTIN. Поэтому
/// он освобождается только тогда, когда держать ему больше некого, — и последним
/// в партии, как того требует порядок сигналов.
#[test]
fn the_shell_is_released_only_when_the_last_guarded_entry_is_gone() {
    // Вторая цель есть в настройках, но её процесса в системе нет: охрана
    // остаётся включённой, а держать ей после снятия первой цели некого.
    let s = stand_guarding(&[CLAUDE, NANO], World::of(terminal_session()), &[]);
    guarded(&s);
    services_go_silent(&s);
    assert_eq!(s.world.signalled(Stop), vec![100, 200, 201]);

    s.world.forget_signals();
    s.settings
        .edit(|settings| settings.targets.retain(|target| target.entry != CLAUDE));
    s.controller.tick();

    assert_eq!(
        s.world.signalled(Resume),
        vec![201, 200, 100],
        "обратный стоп-порядок: потомок, цель, и шелл последним. Партия одна: \
         проход за такт один"
    );
    assert!(
        !s.world.is_stopped(100),
        "держать терминал больше не за чем"
    );
    assert!(s.controller.snapshot().paused.is_empty());

    // Учёт разбирает наблюдение, а его приносит следующий проход: тот, что послал
    // сигнал, видел записи ещё стоящими.
    s.controller.tick();
    assert!(ledger_pids(&s).is_empty(), "учёт опустел по наблюдению");

    let released = s.reporter.recorded().released.clone();
    assert_eq!(
        released.first().map(|(pids, _)| pids.clone()),
        Some(vec![100, 200, 201]),
        "отпущены все три записи, включая шелл: журналу они едут в порядке учёта, \
         а сигналы ушли в обратном — он проверен выше"
    );
    assert_eq!(
        released.last().map(|(_, outcome)| outcome.clone()),
        Some("продолжен: цель снята с охраны".to_string()),
        "исход честный: процесс продолжен, потому что цель ушла из-под охраны"
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

/// Выход зовут дважды: сперва руками — удаление обязано продолжить цели раньше,
/// чем исчезнет учёт, — а потом воронкой, через которую проходит любой выход.
/// Второй раз обязан не делать ничего. Учёт от первого выхода не пустеет:
/// наблюдать результат сигнала уже нечем, и записи остаются до следующего
/// запуска — а без признака «выход уже был» второй вызов слал бы по ним SIGCONT
/// заново и сохранял бы файл учёта, только что снесённый удалением.
#[test]
fn shutdown_twice_changes_nothing_the_second_time() {
    let s = stand();
    guarded(&s);
    services_go_silent(&s);

    s.controller.shutdown();
    let signals_after_first = s.world.signalled(Resume);
    let resolutions_after_first = s.reporter.resolutions();

    s.controller.shutdown();

    assert_eq!(s.world.signalled(Resume), signals_after_first);
    assert_eq!(s.reporter.resolutions(), resolutions_after_first);
    assert_eq!(s.controller.phase(), GuardPhase::Disabled);
}

/// Граница сигналов, умеющая замереть на первом SIGSTOP.
///
/// Подменяется та же граница, что и всегда, — просто она умеет придержать такт
/// ровно посреди применения решения. Иначе поймать гонку «выход против такта»
/// нечем: она измеряется тем, что происходит между двумя сигналами.
#[derive(Clone)]
struct Trap {
    world: World,
    arm: Arc<AtomicBool>,
    entered: Arc<(Mutex<bool>, Condvar)>,
    released: Arc<(Mutex<bool>, Condvar)>,
}

impl Trap {
    fn over(world: World) -> Trap {
        Trap {
            world,
            arm: Arc::new(AtomicBool::new(false)),
            entered: Arc::new((Mutex::new(false), Condvar::new())),
            released: Arc::new((Mutex::new(false), Condvar::new())),
        }
    }

    /// Следующий SIGSTOP замрёт внутри границы.
    fn arm(&self) {
        self.arm.store(true, Ordering::SeqCst);
    }

    fn wait_until_entered(&self) {
        let (lock, cv) = &*self.entered;
        let mut entered = lock.lock().unwrap();
        while !*entered {
            let (guard, timeout) = cv
                .wait_timeout(entered, Duration::from_secs(10))
                .expect("ожидание такта");
            assert!(!timeout.timed_out(), "такт не дошёл до отправки SIGSTOP");
            entered = guard;
        }
    }

    fn release(&self) {
        let (lock, cv) = &*self.released;
        *lock.lock().unwrap() = true;
        cv.notify_all();
    }
}

impl ProcessSignaling for Trap {
    fn send(&self, signal: ProcessSignal, pids: &[i32]) -> Vec<SignalResult> {
        if signal == Stop && self.arm.swap(false, Ordering::SeqCst) {
            let (lock, cv) = &*self.entered;
            *lock.lock().unwrap() = true;
            cv.notify_all();

            let (lock, cv) = &*self.released;
            let mut released = lock.lock().unwrap();
            while !*released {
                released = cv.wait(released).unwrap();
            }
        }
        self.world.send(signal, pids)
    }
}

/// Такт и штатный выход идут в разных потоках, и без общих ворот такт успевал
/// послать SIGSTOP **после** последнего SIGCONT: цель оставалась стоять, а вывести
/// её из стояния было уже некому — такта после выхода не будет.
///
/// Такт здесь пойман ровно на отправке SIGSTOP, и выход зовётся, пока такт ещё
/// идёт. Правильный исход один: выход дожидается такта и продолжает всё,
/// что тот успел остановить.
#[test]
fn a_tick_in_flight_cannot_leave_anything_stopped_after_shutdown() {
    let world = World::of(terminal_session());
    let trap = Trap::over(world.clone());
    let s = build_with_signaler(
        FakeSettings::guarding(&[CLAUDE]),
        world,
        Box::new(trap.clone()),
    );

    let phase = s.controller.tick();
    assert!(matches!(phase, GuardPhase::Protected(_)), "{phase:?}");

    s.geo.everything_goes_silent();
    trap.arm();

    std::thread::scope(|scope| {
        let ticking = scope.spawn(|| s.controller.probe_now());
        trap.wait_until_entered();
        let exiting = scope.spawn(|| s.controller.shutdown());
        // Выход обязан упереться в ворота, а не проскочить мимо такта. Ждать
        // этого нечем, кроме времени: ворота изнутри не видны.
        std::thread::sleep(Duration::from_millis(200));
        trap.release();
        ticking.join().expect("такт");
        exiting.join().expect("выход");
    });

    let signals = s.world.signals();
    let last_resume = signals
        .iter()
        .rposition(|(signal, _)| *signal == Resume)
        .expect("штатный выход обязан послать SIGCONT");
    assert!(
        !signals[last_resume..]
            .iter()
            .any(|(signal, _)| *signal == Stop),
        "после последнего SIGCONT не бывает SIGSTOP: {signals:?}"
    );

    for pid in [100, 200, 201] {
        assert!(
            !s.world.is_stopped(pid),
            "штатный выход замороженных целей не оставляет: {pid} остался стоять"
        );
    }
    let resumed = s.world.signalled(Resume);
    for pid in StoppedLedger::load(&s.ledger_path).pids() {
        assert!(
            resumed.contains(&pid),
            "запись {pid} осталась в учёте без SIGCONT: {signals:?}"
        );
    }
}

/// Вторая половина того же: такт, начавшийся после выхода, не делает ничего.
/// Флага у вершины такта для этого мало — но и ворот без флага мало: событие сети
/// будит поток охраны, и он пошёл бы ставить цели на паузу уже после выхода.
#[test]
fn a_tick_after_shutdown_touches_nothing() {
    let s = stand();
    guarded(&s);
    services_go_silent(&s);

    s.controller.shutdown();
    let signals = s.world.signals();
    let ledger = ledger_pids(&s);

    let phase = s.controller.tick();
    assert_eq!(phase, GuardPhase::Disabled);

    assert_eq!(s.world.signals(), signals, "ни одного нового сигнала");
    assert_eq!(ledger_pids(&s), ledger, "учёт не переписан");
    assert!(
        s.controller.is_shut_down(),
        "по этому признаку поток охраны и выходит из своего цикла"
    );
}
