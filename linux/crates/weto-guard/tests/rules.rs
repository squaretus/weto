//! Правила целей разрешаются заново, а не однажды при добавлении.
//!
//! У версионных инструментов (`~/.local/share/claude/versions/2.1.228`)
//! развёрнутый путь меняется с каждым обновлением. Правило, разрешённое
//! однажды, молча переставало совпадать с новым процессом — и цель выпадала
//! из-под охраны, а VPN-приложение на новом пути считалось закрытым,
//! и охрана завершала цели каждый проход.
//!
//! Подменяются ровно границы: разрешение цели, реестр процессов, сигналы,
//! сеть, гео, часы. Кэш правил, редьюсер и политика работают настоящие.

mod harness;

use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use harness::{build, detached, target, FakeSettings, Harness, World};
use weto_config::settings::{Settings, Target};
use weto_core::guard_machine::{GuardAction, GuardPhase};
use weto_core::policy::UnsafeEvidence;
use weto_core::process::{ProcessSnapshot, TargetKind};
use weto_sys::process_signaler::ProcessSignal::{Kill, Stop};

const LINK: &str = "/home/me/.local/bin/claude";
const V228: &str = "/home/me/.local/share/claude/versions/228";
const V300: &str = "/home/me/.local/share/claude/versions/300";
const V400: &str = "/home/me/.local/share/claude/versions/400";

const HAPP_LINK: &str = "/opt/happ/happ";
const HAPP_1: &str = "/opt/happ/1.0/happ";
const HAPP_2: &str = "/opt/happ/2.0/happ";

/// Переводимые часы: окно повторного разрешения проверяется переводом стрелок.
#[derive(Clone)]
struct Hands(Arc<Mutex<SystemTime>>);

impl Hands {
    fn new() -> Hands {
        Hands(Arc::new(Mutex::new(
            UNIX_EPOCH + Duration::from_secs(1_000_000),
        )))
    }

    fn advance_millis(&self, milliseconds: u64) {
        *self.0.lock().unwrap() += Duration::from_millis(milliseconds);
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

/// Цель, добавленная так, как её добавляет окно настроек: запись — симлинк
/// в `PATH`, путь — во что он развернулся в тот момент.
fn claude(entry: &str, launch_paths: &[&str]) -> Target {
    Target {
        entry: entry.to_string(),
        display_name: "claude".to_string(),
        kind: TargetKind::Binary,
        path: V228.to_string(),
        launch_paths: launch_paths.iter().map(|p| p.to_string()).collect(),
    }
}

fn stand_over(settings: Settings, processes: Vec<ProcessSnapshot>) -> Stand {
    let hands = Hands::new();
    let moving = hands.clone();
    let mut h = build(
        Duration::ZERO,
        FakeSettings(Arc::new(Mutex::new(settings))),
        World::of(processes),
        &[],
    );
    Arc::get_mut(&mut h.controller)
        .expect("часы ставятся до охраны")
        .set_clock(Box::new(move || *moving.0.lock().unwrap()));
    Stand { h, hands }
}

/// claude на 228 под охраной, рядом живой VPN-клиент.
fn stand() -> Stand {
    let settings = Settings {
        vpn_app: Some(target("/usr/bin/happ")),
        blocked_countries: vec!["RU".to_string()],
        targets: vec![claude(LINK, &[LINK])],
        ..Default::default()
    };
    let s = stand_over(
        settings,
        vec![detached(200, 1, V228), detached(77, 1, "/usr/bin/happ")],
    );
    s.resolver.points(LINK, V228);
    s
}

/// Обновление инструмента: симлинк перевешен на новую версию, и с неё
/// запущен новый сеанс.
fn update_to(s: &Stand, path: &str, pid: i32) {
    s.resolver.points(LINK, path);
    s.world.add(detached(pid, 1, path));
}

/// Кого охрана считает живыми целями — по одному pid на сеанс.
fn guarded_pids(s: &Stand) -> Vec<i32> {
    let mut pids: Vec<i32> = s
        .controller
        .snapshot()
        .running
        .iter()
        .map(|running| running.pid)
        .collect();
    pids.sort_unstable();
    pids
}

fn guarded(s: &Stand) {
    let phase = s.tick();
    assert!(matches!(phase, GuardPhase::Protected(_)), "{phase:?}");
}

/// Сервисы замолчали: первый же такой ответ ставит цели на паузу.
fn pause(s: &Stand) -> Vec<i32> {
    s.geo.everything_goes_silent();
    let phase = s.probe_now();
    assert_eq!(phase.action(), GuardAction::Pause, "{phase:?}");
    let mut stopped = s.world.signalled(Stop);
    stopped.sort_unstable();
    stopped
}

// --- тесты -----------------------------------------------------------------

/// Обновление claude перевесило симлинк с 228 на 300: новый сеанс попадает
/// под охрану после окна повторного разрешения — и не раньше.
#[test]
fn an_updated_target_is_followed_after_the_refresh_window_not_within_it() {
    let s = stand();
    guarded(&s);
    assert_eq!(guarded_pids(&s), vec![200]);

    update_to(&s, V300, 300);
    s.hands.advance_millis(1_999);
    s.tick();
    assert_eq!(guarded_pids(&s), vec![200], "внутри окна правило прежнее");

    s.hands.advance_millis(1);
    s.tick();
    assert_eq!(guarded_pids(&s), vec![200, 300]);
    assert_eq!(
        pause(&s),
        vec![200, 300],
        "новый сеанс встаёт вместе со старым"
    );
}

/// Сеанс, начатый до обновления, живёт на прежнем бинарнике — и после
/// повторного разрешения он под охраной. Путь, известный только из памяти
/// охраны (300, в настройках его нет), переживает следующее обновление.
#[test]
fn sessions_on_previous_versions_stay_guarded_after_updates() {
    let s = stand();
    guarded(&s);

    update_to(&s, V300, 300);
    s.hands.advance_millis(2_000);
    s.tick();
    update_to(&s, V400, 400);
    s.hands.advance_millis(2_000);
    s.tick();

    assert_eq!(guarded_pids(&s), vec![200, 300, 400]);
    assert_eq!(pause(&s), vec![200, 300, 400]);
}

/// Пока обновление подменяет файл, запись на мгновение ни во что
/// не разрешается. Правило от этого не пропадает и не откатывается
/// к пути из настроек: живой сеанс в этот момент никуда не девается.
#[test]
fn a_target_that_momentarily_does_not_resolve_keeps_its_last_rule() {
    let s = stand();
    guarded(&s);
    update_to(&s, V300, 300);
    s.hands.advance_millis(2_000);
    s.tick();
    assert_eq!(guarded_pids(&s), vec![200, 300]);

    s.resolver.loses(LINK);
    s.hands.advance_millis(2_000);
    s.tick();

    assert_eq!(guarded_pids(&s), vec![200, 300]);
    assert_eq!(pause(&s), vec![200, 300]);
}

/// Разрешение лезет в файловую систему, а под паузой проход идёт раз
/// в 250 мс: внутри окна диск не спрашивается ни разу. Правка списка целей
/// пересчитывает правила сразу, не дожидаясь окна.
#[test]
fn rules_are_not_resolved_again_within_the_refresh_window() {
    let s = stand();
    guarded(&s);
    let after_first = s.resolver.calls();
    assert!(after_first > 0, "первый проход разрешает цели");

    for _ in 0..7 {
        s.hands.advance_millis(250);
        s.tick();
    }
    assert_eq!(
        s.resolver.calls(),
        after_first,
        "внутри окна диск не трогается"
    );

    s.hands.advance_millis(250);
    s.tick();
    let after_window = s.resolver.calls();
    assert!(
        after_window > after_first,
        "окно истекло — разрешение заново"
    );

    s.settings
        .edit(|settings| settings.targets.push(target("/usr/bin/nano")));
    s.tick();
    assert!(
        s.resolver.calls() > after_window,
        "правка целей пересчитывает правила без ожидания окна"
    );
}

/// VPN-клиент обновился сам и живёт теперь на другом пути. Правило,
/// разрешённое однажды, считало бы его закрытым — и охрана завершала бы
/// цели каждый проход по «VPN-приложение не запущено».
#[test]
fn a_vpn_app_on_a_new_path_is_still_running() {
    let settings = Settings {
        vpn_app: Some(Target {
            entry: HAPP_LINK.to_string(),
            display_name: "Happ".to_string(),
            kind: TargetKind::Binary,
            path: HAPP_1.to_string(),
            launch_paths: vec![HAPP_LINK.to_string()],
        }),
        blocked_countries: vec!["RU".to_string()],
        targets: vec![claude(LINK, &[LINK])],
        ..Default::default()
    };
    let s = stand_over(
        settings,
        vec![detached(200, 1, V228), detached(77, 1, HAPP_1)],
    );
    s.resolver.points(LINK, V228);
    s.resolver.points(HAPP_LINK, HAPP_1);
    guarded(&s);

    s.world.remove(77);
    s.world.add(detached(78, 1, HAPP_2));
    s.resolver.points(HAPP_LINK, HAPP_2);
    s.hands.advance_millis(2_000);
    let phase = s.tick();

    assert!(
        !matches!(phase, GuardPhase::Danger(UnsafeEvidence::VpnAppNotRunning)),
        "{phase:?}"
    );
    assert!(matches!(phase, GuardPhase::Protected(_)), "{phase:?}");
    assert!(s.world.signalled(Kill).is_empty());
}

/// Голое имя, которого нет в `PATH` охраны, находится по файлу в `PATH`,
/// запомненному при добавлении: с него разрешение и начинается.
#[test]
fn a_bare_name_missing_from_the_guard_path_is_found_by_its_path_entry() {
    let settings = Settings {
        vpn_app: Some(target("/usr/bin/happ")),
        blocked_countries: vec!["RU".to_string()],
        targets: vec![claude("claude", &["claude", LINK])],
        ..Default::default()
    };
    let s = stand_over(
        settings,
        vec![detached(300, 1, V300), detached(77, 1, "/usr/bin/happ")],
    );
    s.resolver.points(LINK, V300);

    guarded(&s);

    assert_eq!(guarded_pids(&s), vec![300]);
}
