//! Машина состояний охраны на подменённых границах.
//!
//! Подменяются ровно границы: снимок сети, гео-проба, реестр процессов,
//! завершение, хранилище секрета. Внутренние типы — никогда.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use weto_config::settings::{Settings, Target};
use weto_core::geo::{ConfirmSource, GeoFailure, GeoProbeReport, SourceOutcome};
use weto_core::network::{NetworkInterfaceSnapshot, NetworkSnapshot};
use weto_core::policy::{GuardDecision, UnsafeReason};
use weto_core::process::{ProcessSnapshot, TargetKind};
use weto_guard::controller::{GuardController, KillReporting, SettingsProviding};
use weto_guard::enforcer::ProcessEnforcer;
use weto_sys::geo_probe::GeoProbing;
use weto_sys::network_snapshot::NetworkSnapshotReading;
use weto_sys::process_killer::ProcessKilling;
use weto_sys::process_registry::ProcessRegistryReading;
use weto_sys::secret_store::{SecretError, SecretStoring};

// --- границы ---------------------------------------------------------------

#[derive(Clone)]
struct FakeNetwork(Arc<Mutex<NetworkSnapshot>>);

impl FakeNetwork {
    fn healthy_tunnel() -> FakeNetwork {
        FakeNetwork(Arc::new(Mutex::new(NetworkSnapshot {
            interfaces: vec![interface("wg0", true, true), interface("eth0", true, false)],
            default_route_interface: Some("wg0".to_string()),
        })))
    }

    fn route_moves_to(&self, name: &str) {
        self.0.lock().unwrap().default_route_interface = Some(name.to_string());
    }

    fn foreign_tunnel_appears(&self, name: &str) {
        self.0
            .lock()
            .unwrap()
            .interfaces
            .push(interface(name, true, true));
    }

    fn tunnel_goes_down(&self) {
        let mut snapshot = self.0.lock().unwrap();
        snapshot.interfaces[0].is_up = false;
        snapshot.default_route_interface = Some("eth0".to_string());
    }
}

fn interface(name: &str, is_up: bool, is_tunnel: bool) -> NetworkInterfaceSnapshot {
    NetworkInterfaceSnapshot {
        name: name.to_string(),
        index: 1,
        is_up,
        is_tunnel,
    }
}

impl NetworkSnapshotReading for FakeNetwork {
    fn snapshot(&self) -> NetworkSnapshot {
        self.0.lock().unwrap().clone()
    }
}

#[derive(Clone)]
struct FakeGeo {
    country: Arc<Mutex<String>>,
    calls: Arc<AtomicUsize>,
    /// Адрес, который называет резервный сервис, когда ipinfo молчит.
    silent_ipinfo: Arc<Mutex<Option<String>>>,
}

impl FakeGeo {
    fn safe() -> FakeGeo {
        FakeGeo {
            country: Arc::new(Mutex::new("NL".to_string())),
            calls: Arc::new(AtomicUsize::new(0)),
            silent_ipinfo: Arc::new(Mutex::new(None)),
        }
    }

    fn now_reports(&self, country: &str) {
        *self.country.lock().unwrap() = country.to_string();
    }

    /// ipinfo молчит, а адрес называет резервный сервис — та самая форма отчёта,
    /// которую отдаёт проба при 429 от ipinfo.
    fn ipinfo_goes_silent(&self, address_from_reference: &str) {
        *self.silent_ipinfo.lock().unwrap() = Some(address_from_reference.to_string());
    }

    fn call_count(&self) -> usize {
        self.calls.load(Ordering::SeqCst)
    }
}

impl GeoProbing for FakeGeo {
    fn probe(&self, _token: Option<&str>) -> GeoProbeReport {
        self.calls.fetch_add(1, Ordering::SeqCst);
        let country = self.country.lock().unwrap().clone();

        if let Some(address) = self.silent_ipinfo.lock().unwrap().clone() {
            return GeoProbeReport {
                ip: Some(address),
                ipinfo: SourceOutcome::Failed(GeoFailure::RateLimited(429)),
                confirmation: SourceOutcome::Answered(country),
                confirm_source: Some(ConfirmSource::Geojs),
                has_network_path: true,
                checked_at: SystemTime::now(),
            };
        }

        GeoProbeReport {
            ip: Some("203.0.113.7".to_string()),
            ipinfo: SourceOutcome::Answered(country.clone()),
            confirmation: SourceOutcome::Answered(country),
            confirm_source: Some(ConfirmSource::Freeipapi),
            has_network_path: true,
            checked_at: SystemTime::now(),
        }
    }
}

#[derive(Clone)]
struct FakeProcesses(Arc<Mutex<Vec<ProcessSnapshot>>>);

impl ProcessRegistryReading for FakeProcesses {
    fn snapshot(&self) -> Vec<ProcessSnapshot> {
        self.0.lock().unwrap().clone()
    }
}

#[derive(Clone, Default)]
struct RecordingKiller(Arc<Mutex<Vec<i32>>>);

impl RecordingKiller {
    fn killed(&self) -> Vec<i32> {
        self.0.lock().unwrap().clone()
    }
}

impl ProcessKilling for RecordingKiller {
    fn kill(&self, pids: &[i32]) -> Vec<i32> {
        self.0.lock().unwrap().extend_from_slice(pids);
        pids.to_vec()
    }
}

struct NoSecret;

impl SecretStoring for NoSecret {
    fn load(&self) -> Result<Option<String>, SecretError> {
        Ok(Some("token".to_string()))
    }
    fn save(&self, _token: &str) -> Result<(), SecretError> {
        Ok(())
    }
    fn delete(&self) -> Result<(), SecretError> {
        Ok(())
    }
}

#[derive(Clone)]
struct FakeSettings(Arc<Mutex<Settings>>);

impl FakeSettings {
    fn armed() -> FakeSettings {
        let settings = Settings {
            vpn_interface: Some("wg0".to_string()),
            blocked_countries: vec!["RU".to_string()],
            targets: vec![Target {
                entry: "/usr/bin/nano".to_string(),
                display_name: "nano".to_string(),
                kind: TargetKind::Binary,
                path: "/usr/bin/nano".to_string(),
                launch_paths: vec![],
            }],
            ..Default::default()
        };
        FakeSettings(Arc::new(Mutex::new(settings)))
    }

    fn edit(&self, change: impl FnOnce(&mut Settings)) {
        let mut settings = self.0.lock().unwrap();
        change(&mut settings);
        settings.revision += 1;
    }
}

impl SettingsProviding for FakeSettings {
    fn settings(&self) -> Settings {
        self.0.lock().unwrap().clone()
    }
}

#[derive(Clone, Default)]
struct RecordingReporter(Arc<Mutex<Vec<String>>>);

impl KillReporting for RecordingReporter {
    fn report(&self, _killed: &[weto_core::process::MatchedProcess], reason: &str) {
        self.0.lock().unwrap().push(reason.to_string());
    }
}

// --- сборка ----------------------------------------------------------------

struct Harness {
    controller: GuardController,
    network: FakeNetwork,
    geo: FakeGeo,
    settings: FakeSettings,
    killer: RecordingKiller,
    reporter: RecordingReporter,
}

/// Без окна коалесценции: почти всем случаям оно только мешает, а проверяется
/// оно отдельным тестом.
fn harness() -> Harness {
    harness_with_window(std::time::Duration::ZERO)
}

fn harness_with_window(window: std::time::Duration) -> Harness {
    let network = FakeNetwork::healthy_tunnel();
    let geo = FakeGeo::safe();
    let settings = FakeSettings::armed();
    let killer = RecordingKiller::default();
    let reporter = RecordingReporter::default();
    let processes = FakeProcesses(Arc::new(Mutex::new(vec![ProcessSnapshot {
        pid: 42,
        parent_pid: 1,
        executable_path: "/usr/bin/nano".to_string(),
        arguments: Some(vec!["nano".to_string()]),
    }])));

    let controller = GuardController::new(
        Box::new(network.clone()),
        Box::new(geo.clone()),
        Box::new(NoSecret),
        Box::new(settings.clone()),
        ProcessEnforcer::new(Box::new(processes), Box::new(killer.clone())),
        Box::new(reporter.clone()),
    )
    .with_coalesce_window(window);

    Harness {
        controller,
        network,
        geo,
        settings,
        killer,
        reporter,
    }
}

fn reason(decision: &GuardDecision) -> Option<&UnsafeReason> {
    match decision {
        GuardDecision::Kill(reason) => Some(reason),
        GuardDecision::Safe => None,
    }
}

// --- тесты -----------------------------------------------------------------

/// Первый такт вердикта не имеет, поэтому обязан быть fail-closed,
/// а сразу за этим — сходить в сеть и снять блокировку.
#[test]
fn the_first_tick_is_fail_closed_and_then_resolves() {
    let h = harness();

    let decision = h.controller.tick();

    assert_eq!(decision, GuardDecision::Safe);
    assert_eq!(h.geo.call_count(), 1);
    assert_eq!(
        h.killer.killed(),
        vec![42],
        "до ответа сети цели завершаются — это и есть fail-closed"
    );
}

/// Без признака свежести цели умирали бы каждые пять секунд при исправном VPN.
#[test]
fn a_routine_tick_with_a_healthy_vpn_does_not_touch_the_targets() {
    let h = harness();
    h.controller.tick();
    let killed_after_first = h.killer.killed().len();

    let decision = h.controller.tick();

    assert_eq!(decision, GuardDecision::Safe);
    assert_eq!(h.killer.killed().len(), killed_after_first);
    assert_eq!(
        h.geo.call_count(),
        1,
        "второй запрос не нужен: ничего не изменилось"
    );
}

/// Второй VPN, живущий рядом, — не событие для охраны.
///
/// Корпоративный клиент рвёт связь и поднимается сам: его туннель уходит
/// из снимка и возвращается. Выбранный интерфейс и владелец маршрута при этом
/// не шелохнулись, значит и вердикт остался в силе.
#[test]
fn a_foreign_vpn_reconnecting_does_not_touch_the_targets() {
    let h = harness();
    h.controller.tick();
    let killed_after_first = h.killer.killed().len();

    h.network.foreign_tunnel_appears("cscotun0");
    let decision = h.controller.tick();

    assert_eq!(decision, GuardDecision::Safe);
    assert_eq!(h.killer.killed().len(), killed_after_first);
    assert_eq!(
        h.geo.call_count(),
        1,
        "чужой туннель не повод ни завершать цели, ни тратить запрос"
    );
}

/// Смена владельца маршрута обесценивает вердикт ещё до всякого запроса.
/// Локальное основание применяется до сети и сетью не отменяется.
///
/// Запрос при этом уходит — но только за показаниями: экран обязан сказать,
/// где пользователь оказался, когда трафик пошёл мимо туннеля. Раньше здесь
/// проверялось отсутствие запроса вовсе, и ценой этого был экран, навсегда
/// застывший на стране упавшего VPN.
#[test]
fn moving_the_route_off_the_tunnel_kills_before_the_network_is_asked() {
    let h = harness();
    h.controller.tick();

    h.geo.now_reports("KZ");
    h.network.route_moves_to("eth0");
    let decision = h.controller.tick();

    assert_eq!(reason(&decision), Some(&UnsafeReason::VpnNotPrimary));
    // Ответ сети «страна безопасная» вердикт не меняет: цели завершены.
    assert!(!h.killer.killed().is_empty());
}

#[test]
fn a_tunnel_that_went_down_is_noticed_locally() {
    let h = harness();
    h.controller.tick();

    h.network.tunnel_goes_down();
    let decision = h.controller.tick();

    assert_eq!(reason(&decision), Some(&UnsafeReason::VpnDown));
}

/// Правка настроек меняет ревизию, а значит обесценивает прежний вердикт.
#[test]
fn editing_the_settings_invalidates_the_verdict() {
    let h = harness();
    h.controller.tick();
    let calls_before = h.geo.call_count();

    h.settings
        .edit(|s| s.blocked_countries.push("DE".to_string()));
    h.controller.tick();

    assert_eq!(
        h.geo.call_count(),
        calls_before + 1,
        "после правки настроек вердикт нужно получать заново"
    );
}

/// У подтверждающего сервиса лимит 60 запросов в минуту. Всплеск событий сети
/// не должен превращаться во всплеск запросов — но и цели в это окно не живут:
/// вердикта нет, значит fail-closed.
#[test]
fn a_burst_of_changes_does_not_become_a_burst_of_requests() {
    let h = harness_with_window(std::time::Duration::from_millis(300));
    h.controller.tick();
    let calls_after_first = h.geo.call_count();

    h.settings
        .edit(|s| s.blocked_countries.push("DE".to_string()));
    let decision = h.controller.tick();

    assert_eq!(
        h.geo.call_count(),
        calls_after_first,
        "второй запрос придержан окном"
    );
    assert_eq!(
        reason(&decision),
        Some(&UnsafeReason::VerificationPending),
        "придержали запрос — значит вердикта нет, значит цели завершены"
    );

    std::thread::sleep(std::time::Duration::from_millis(350));
    h.controller.tick();
    assert_eq!(
        h.geo.call_count(),
        calls_after_first + 1,
        "за пределами окна запрос обязан уйти"
    );
}

#[test]
fn a_blocked_country_kills_and_names_the_source() {
    let h = harness();
    h.controller.tick();

    h.geo.now_reports("RU");
    h.settings.edit(|_| {}); // сбрасываем свежесть, чтобы проба ушла заново
    let decision = h.controller.tick();

    assert_eq!(
        reason(&decision),
        Some(&UnsafeReason::BlockedCountry {
            code: "RU".to_string(),
            source: "ipinfo".to_string()
        })
    );
    assert!(h
        .reporter
        .0
        .lock()
        .unwrap()
        .iter()
        .any(|r| r.contains("RU")));
}

/// Кнопка спрашивает «где я», а не «нужна ли проверка»: запрос уходит даже
/// тогда, когда судьба целей решена локально.
#[test]
fn the_button_asks_the_network_even_when_the_verdict_is_local() {
    let h = harness();
    h.network.tunnel_goes_down();
    h.controller.tick();
    let calls_before = h.geo.call_count();

    let decision = h.controller.probe_now();

    assert_eq!(
        reason(&decision),
        Some(&UnsafeReason::VpnDown),
        "локальное основание применяется сразу, жизни целям кнопка не продлевает"
    );
    assert_eq!(h.geo.call_count(), calls_before + 1);
    assert!(
        h.controller.snapshot().report.is_some(),
        "экран обязан показать страну, ради которой кнопку и нажали"
    );
}

/// Нажатие при исправном VPN не должно ронять состояние в ожидание проверки:
/// иначе кнопка стоила бы пользователю целей.
#[test]
fn the_button_does_not_cost_the_user_their_targets() {
    let h = harness();
    h.controller.tick();
    let killed_before = h.killer.killed().len();

    let decision = h.controller.probe_now();

    assert_eq!(decision, GuardDecision::Safe);
    assert_eq!(h.killer.killed().len(), killed_before);
}

#[test]
fn the_screen_shows_which_tunnels_can_be_chosen() {
    let h = harness();
    h.controller.tick();

    assert_eq!(h.controller.snapshot().vpn_candidates, vec!["wg0"]);
}

#[test]
fn a_disabled_guard_leaves_everything_alone() {
    let h = harness();
    h.settings.edit(|s| s.is_enabled = false);

    let decision = h.controller.tick();

    assert_eq!(decision, GuardDecision::Safe);
    assert!(h.killer.killed().is_empty());
    assert_eq!(h.geo.call_count(), 0, "выключенной охране сеть не нужна");
}

#[test]
fn without_targets_there_is_nothing_to_guard() {
    let h = harness();
    h.settings.edit(|s| s.targets.clear());

    let decision = h.controller.tick();

    assert_eq!(decision, GuardDecision::Safe);
    assert_eq!(h.geo.call_count(), 0);
}

#[test]
fn an_unchosen_tunnel_is_its_own_reason() {
    let h = harness();
    h.settings.edit(|s| s.vpn_interface = None);

    let decision = h.controller.tick();

    assert_eq!(reason(&decision), Some(&UnsafeReason::VpnNotConfigured));
}

#[test]
fn running_targets_are_reported_for_the_screen() {
    let h = harness();
    h.controller.tick();

    let running = h.controller.snapshot().running;
    assert_eq!(running.len(), 1);
    assert_eq!(running[0].display_name, "nano");
}

/// Показания обязаны обновляться при падении VPN.
///
/// Судьба целей решается локально и в сеть за ней ходить незачем — но экран
/// отвечает на другой вопрос: «где я сейчас». Пока экономию запросов
/// распространяли и на него, после выключения VPN там навсегда оставались
/// адрес и страна туннеля, то есть экран показывал защиту, которой уже нет.
#[test]
fn the_readout_refreshes_when_the_tunnel_falls() {
    let h = harness();

    h.controller.tick();
    let probes_while_guarded = h.geo.call_count();
    assert!(probes_while_guarded > 0, "на страже проба обязана быть");
    assert!(h.controller.snapshot().report.is_some());

    // VPN выключили: судьба целей ясна без сети, но показания устарели.
    h.geo.now_reports("KZ");
    h.network.tunnel_goes_down();
    let decision = h.controller.tick();

    assert_eq!(reason(&decision), Some(&UnsafeReason::VpnDown));
    assert!(
        h.geo.call_count() > probes_while_guarded,
        "после падения VPN показания обязаны обновиться"
    );

    let report = h
        .controller
        .snapshot()
        .report
        .expect("показания должны быть свежими, а не пустыми");
    assert_eq!(report.reference_country().or(Some("KZ")), Some("KZ"));
}

/// Обновление — одно на смену состояния сети, а не на каждый такт: у
/// подтверждающего сервиса лимит, и опрашивать его пять раз в минуту впустую
/// значило бы его исчерпать.
#[test]
fn a_settled_local_verdict_does_not_probe_every_tick() {
    let h = harness();

    h.network.tunnel_goes_down();
    h.controller.tick();
    let after_first = h.geo.call_count();

    for _ in 0..5 {
        h.controller.tick();
    }

    assert_eq!(
        h.geo.call_count(),
        after_first,
        "состояние сети не менялось — новых запросов быть не должно"
    );
}

/// Молчание ipinfo — не повод завершать цели, если адрес доказанно тот же.
/// Тот же адрес — та же страна.
#[test]
fn silent_ipinfo_with_the_same_address_keeps_the_targets() {
    let h = harness();
    assert_eq!(h.controller.tick(), GuardDecision::Safe);
    // Первый круг всегда fail-closed до ответа сети, и его завершения уже в списке.
    let killed_before = h.killer.killed().len();

    h.geo.ipinfo_goes_silent("203.0.113.7");
    std::thread::sleep(Duration::from_millis(20));

    assert_eq!(
        h.controller.probe_now(),
        GuardDecision::Safe,
        "адрес тот же — перепроверять нечего"
    );
    assert_eq!(
        h.killer.killed().len(),
        killed_before,
        "молчание ipinfo при неизменном адресе целей не стоит"
    );
}

/// Адрес другой, страны для него никто не назвал — вердикта нет, и снисхождения тоже.
#[test]
fn silent_ipinfo_with_a_new_address_kills() {
    let h = harness();
    assert_eq!(h.controller.tick(), GuardDecision::Safe);

    h.geo.ipinfo_goes_silent("198.51.100.231");
    let decision = h.controller.probe_now();

    assert_eq!(
        reason(&decision),
        Some(&UnsafeReason::GeoUnavailable(
            "адрес сменился, страна не проверена".to_string()
        ))
    );
}

/// Расписание гео: страна выхода меняется и на неизменном пути, поэтому запрос
/// уходит и без событий сети.
#[test]
fn geo_schedule_asks_again_on_an_unchanged_path() {
    let h = harness();
    h.controller.tick();
    let calls_after_verdict = h.geo.call_count();

    // Тик сразу за первым: расписание ещё не подошло, в сеть идти незачем.
    h.controller.tick();
    assert_eq!(
        h.geo.call_count(),
        calls_after_verdict,
        "частота запросов не равна частоте тиков"
    );
}
