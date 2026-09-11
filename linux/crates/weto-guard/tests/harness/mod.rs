//! Сборка охраны на подменённых границах.
//!
//! Подменяются ровно границы: снимок сети, гео-проба, реестр процессов, сигналы,
//! хранилище секрета. Внутренние типы — никогда: и политика, и редьюсер, и план
//! паузы, и учёт остановленных работают настоящие.
//!
//! Мир процессов один на реестр и на сигналы: иначе «остановлено» и «наблюдено
//! стоящим» были бы двумя независимыми выдумками теста, а весь смысл паузы —
//! в том, что обязательство снимает наблюдение, а не отправка сигнала.

#![allow(dead_code)]

use std::collections::HashSet;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::SystemTime;

use weto_config::settings::{Settings, Target};
use weto_core::check::CheckEvent;
use weto_core::diagnostics::KillContext;
use weto_core::geo::{ConfirmSource, GeoFailure, GeoProbeReport, SourceOutcome};
use weto_core::network::{NetworkSnapshot, OutgoingRoute};
use weto_core::pause_plan::RecoveredProcess;
use weto_core::process::{MatchedProcess, ProcessSnapshot, TargetKind};
use weto_guard::controller::{CheckReporting, GuardController, KillReporting, SettingsProviding};
use weto_guard::enforcer::ProcessEnforcer;
use weto_sys::geo_probe::GeoProbing;
use weto_sys::network_snapshot::NetworkSnapshotReading;
use weto_sys::process_registry::ProcessRegistryReading;
use weto_sys::process_signaler::{ProcessSignal, ProcessSignaling, SignalResult};
use weto_sys::secret_store::{SecretError, SecretStoring};

// --- сеть -------------------------------------------------------------------

#[derive(Clone)]
pub struct FakeNetwork(Arc<Mutex<NetworkSnapshot>>);

impl FakeNetwork {
    pub fn healthy_tunnel() -> FakeNetwork {
        FakeNetwork(Arc::new(Mutex::new(NetworkSnapshot {
            outgoing: Some(OutgoingRoute {
                interface: "wg0".to_string(),
                address: "10.7.0.2".to_string(),
            }),
        })))
    }

    pub fn route_moves_to(&self, name: &str) {
        self.0.lock().unwrap().outgoing = Some(OutgoingRoute {
            interface: name.to_string(),
            address: "10.7.0.2".to_string(),
        });
    }

    /// Туннель упал: трафик пошёл напрямую.
    pub fn tunnel_goes_down(&self) {
        self.0.lock().unwrap().outgoing = Some(OutgoingRoute {
            interface: "eth0".to_string(),
            address: "192.168.1.10".to_string(),
        });
    }
}

impl NetworkSnapshotReading for FakeNetwork {
    fn snapshot(&self) -> NetworkSnapshot {
        self.0.lock().unwrap().clone()
    }
}

// --- гео --------------------------------------------------------------------

#[derive(Clone)]
pub struct FakeGeo {
    country: Arc<Mutex<String>>,
    calls: Arc<AtomicUsize>,
    /// Адрес, который называет резервный сервис, когда ipinfo молчит.
    silent_ipinfo: Arc<Mutex<Option<String>>>,
    /// Молчат оба: ни адреса, ни страны.
    silent_everything: Arc<Mutex<bool>>,
}

impl FakeGeo {
    pub fn safe() -> FakeGeo {
        FakeGeo {
            country: Arc::new(Mutex::new("NL".to_string())),
            calls: Arc::new(AtomicUsize::new(0)),
            silent_ipinfo: Arc::new(Mutex::new(None)),
            silent_everything: Arc::new(Mutex::new(false)),
        }
    }

    pub fn now_reports(&self, country: &str) {
        *self.country.lock().unwrap() = country.to_string();
    }

    /// ipinfo молчит, а адрес называет резервный сервис — та самая форма отчёта,
    /// которую отдаёт проба при 429 от ipinfo.
    pub fn ipinfo_goes_silent(&self, address_from_reference: &str) {
        *self.silent_ipinfo.lock().unwrap() = Some(address_from_reference.to_string());
    }

    /// Молчат все: адреса нет вовсе, вердикта нет — это `unproven`.
    pub fn everything_goes_silent(&self) {
        *self.silent_everything.lock().unwrap() = true;
    }

    pub fn everything_answers_again(&self) {
        *self.silent_everything.lock().unwrap() = false;
        *self.silent_ipinfo.lock().unwrap() = None;
    }

    pub fn call_count(&self) -> usize {
        self.calls.load(Ordering::SeqCst)
    }
}

impl GeoProbing for FakeGeo {
    fn probe(&self, _token: Option<&str>) -> GeoProbeReport {
        self.calls.fetch_add(1, Ordering::SeqCst);
        let country = self.country.lock().unwrap().clone();

        if *self.silent_everything.lock().unwrap() {
            return GeoProbeReport {
                ip: None,
                ipinfo: SourceOutcome::Failed(GeoFailure::TimedOut),
                confirmation: SourceOutcome::Failed(GeoFailure::TimedOut),
                confirm_source: None,
                has_network_path: true,
                checked_at: SystemTime::now(),
                traces: Vec::new(),
            };
        }

        if let Some(address) = self.silent_ipinfo.lock().unwrap().clone() {
            return GeoProbeReport {
                ip: Some(address),
                ipinfo: SourceOutcome::Failed(GeoFailure::RateLimited(429)),
                confirmation: SourceOutcome::Answered(country),
                confirm_source: Some(ConfirmSource::Geojs),
                has_network_path: true,
                checked_at: SystemTime::now(),
                traces: Vec::new(),
            };
        }

        GeoProbeReport {
            ip: Some("203.0.113.7".to_string()),
            ipinfo: SourceOutcome::Answered(country.clone()),
            confirmation: SourceOutcome::Answered(country),
            confirm_source: Some(ConfirmSource::Freeipapi),
            has_network_path: true,
            checked_at: SystemTime::now(),
            traces: Vec::new(),
        }
    }
}

// --- мир процессов ----------------------------------------------------------

/// Таблица процессов вместе с тем, что с ней делают сигналы.
///
/// Один объект на реестр и на сигналы намеренно: SIGSTOP обязан быть виден
/// следующему обходу, SIGCONT — снимать стояние, SIGKILL — убирать процесс.
/// Иначе проверять «обязательство снимает наблюдение» было бы нечем.
#[derive(Clone, Default)]
pub struct World(Arc<Mutex<WorldInner>>);

#[derive(Default)]
struct WorldInner {
    processes: Vec<ProcessSnapshot>,
    /// Порядок фактических вызовов `kill(2)`.
    signals: Vec<(ProcessSignal, i32)>,
    /// Кому ядро отказывает (EPERM).
    refused: HashSet<i32>,
    /// Фоновые задания: SIGCONT их будит, но tty тут же возвращает их в стоп
    /// по SIGTTIN — ровно то, ради чего обязательство держится до наблюдения.
    background: HashSet<i32>,
}

impl World {
    pub fn of(processes: Vec<ProcessSnapshot>) -> World {
        World(Arc::new(Mutex::new(WorldInner {
            processes,
            ..WorldInner::default()
        })))
    }

    pub fn add(&self, process: ProcessSnapshot) {
        self.0.lock().unwrap().processes.push(process);
    }

    pub fn remove(&self, pid: i32) {
        self.0.lock().unwrap().processes.retain(|p| p.pid != pid);
    }

    /// Пользователь закрыл VPN-клиент.
    pub fn vpn_app_closes(&self) {
        self.remove(77);
    }

    pub fn refuses(&self, pid: i32) {
        self.0.lock().unwrap().refused.insert(pid);
    }

    /// Задание фоновое: на каждый SIGCONT оно отвечает новым стопом.
    pub fn is_background_job(&self, pid: i32) {
        self.0.lock().unwrap().background.insert(pid);
    }

    /// Пользователь ввёл `fg`: шелл вернул заданию терминал и снял его со стопа.
    /// Сигнала от weto тут нет вовсе — и именно поэтому обязательство обязано
    /// сниматься наблюдением.
    pub fn brought_to_foreground(&self, pid: i32) {
        let mut world = self.0.lock().unwrap();
        world.background.remove(&pid);
        if let Some(process) = world.processes.iter_mut().find(|p| p.pid == pid) {
            process.is_stopped = false;
        }
    }

    pub fn is_stopped(&self, pid: i32) -> bool {
        self.0
            .lock()
            .unwrap()
            .processes
            .iter()
            .any(|p| p.pid == pid && p.is_stopped)
    }

    pub fn is_alive(&self, pid: i32) -> bool {
        self.0
            .lock()
            .unwrap()
            .processes
            .iter()
            .any(|p| p.pid == pid)
    }

    /// Все вызовы ядра в порядке отправки.
    pub fn signals(&self) -> Vec<(ProcessSignal, i32)> {
        self.0.lock().unwrap().signals.clone()
    }

    /// pid, получившие этот сигнал, в порядке отправки.
    pub fn signalled(&self, signal: ProcessSignal) -> Vec<i32> {
        self.0
            .lock()
            .unwrap()
            .signals
            .iter()
            .filter(|(kind, _)| *kind == signal)
            .map(|(_, pid)| *pid)
            .collect()
    }

    pub fn forget_signals(&self) {
        self.0.lock().unwrap().signals.clear();
    }
}

impl ProcessRegistryReading for World {
    fn snapshot(&self) -> Vec<ProcessSnapshot> {
        self.0.lock().unwrap().processes.clone()
    }
}

impl ProcessSignaling for World {
    fn send(&self, signal: ProcessSignal, pids: &[i32]) -> Vec<SignalResult> {
        let mut world = self.0.lock().unwrap();
        let mut results = Vec::new();
        for pid in pids {
            world.signals.push((signal, *pid));
            if world.refused.contains(pid) {
                results.push(SignalResult {
                    pid: *pid,
                    error_code: Some(libc::EPERM),
                });
                continue;
            }
            let background = world.background.contains(pid);
            match signal {
                ProcessSignal::Stop => {
                    if let Some(process) = world.processes.iter_mut().find(|p| p.pid == *pid) {
                        process.is_stopped = true;
                    }
                }
                ProcessSignal::Resume => {
                    if let Some(process) = world.processes.iter_mut().find(|p| p.pid == *pid) {
                        // Фоновое задание просыпается, читает tty, получает
                        // SIGTTIN и встаёт обратно — к следующему обходу оно
                        // снова стоит.
                        process.is_stopped = background;
                    }
                }
                ProcessSignal::Kill => {
                    world.processes.retain(|p| p.pid != *pid);
                }
            }
            results.push(SignalResult {
                pid: *pid,
                error_code: None,
            });
        }
        results
    }
}

// --- секрет и настройки -----------------------------------------------------

pub struct NoSecret;

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
pub struct FakeSettings(pub Arc<Mutex<Settings>>);

impl FakeSettings {
    pub fn armed() -> FakeSettings {
        FakeSettings::guarding(&["/usr/bin/nano"])
    }

    pub fn guarding(paths: &[&str]) -> FakeSettings {
        let settings = Settings {
            vpn_app: Some(target("/usr/bin/happ")),
            blocked_countries: vec!["RU".to_string()],
            targets: paths.iter().map(|path| target(path)).collect(),
            ..Default::default()
        };
        FakeSettings(Arc::new(Mutex::new(settings)))
    }

    pub fn edit(&self, change: impl FnOnce(&mut Settings)) {
        let mut settings = self.0.lock().unwrap();
        change(&mut settings);
        settings.revision += 1;
    }
}

pub fn target(path: &str) -> Target {
    Target {
        entry: path.to_string(),
        display_name: path.rsplit('/').next().unwrap_or(path).to_string(),
        kind: TargetKind::Binary,
        path: path.to_string(),
        launch_paths: vec![],
    }
}

impl SettingsProviding for FakeSettings {
    fn settings(&self) -> Settings {
        self.0.lock().unwrap().clone()
    }
}

// --- приёмники --------------------------------------------------------------

/// Приёмник проверок: тесты смотрят, что записалось про попытки — включая те,
/// где запрос так и не ушёл.
#[derive(Clone, Default)]
pub struct RecordingChecks(pub Arc<Mutex<Vec<CheckEvent>>>);

impl RecordingChecks {
    pub fn events(&self) -> Vec<CheckEvent> {
        self.0.lock().unwrap().clone()
    }
}

impl CheckReporting for RecordingChecks {
    fn record(&self, event: CheckEvent) {
        self.0.lock().unwrap().push(event);
    }
}

/// Одна запись журнала глазами теста: кто, по какой причине и каким основанием.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub pid: i32,
    pub target_name: String,
    pub reason: String,
    pub matched_by: weto_core::process::MatchBasis,
}

#[derive(Clone, Default)]
pub struct RecordingReporter(Arc<Mutex<Recorded>>);

#[derive(Default)]
pub struct Recorded {
    /// Причины завершений в порядке поступления.
    pub kill_reasons: Vec<String>,
    /// Завершённые процессы: про них уходит уведомление.
    pub killed: Vec<i32>,
    /// Те из них, про кого заводится запись журнала: стоявшую цель эпизод паузы
    /// уже описал, и второй записи про тот же pid не бывает.
    pub recordable: Vec<i32>,
    /// Контексты завершений: по ним проверяется диагностика, а не только текст.
    pub kill_contexts: Vec<KillContext>,
    /// Сколько раз эпизод объявлен законченным.
    pub finished: usize,
    /// Записи «на паузе»: цели, потомки и шеллы.
    pub paused: Vec<Entry>,
    /// Записи эпизода восстановления.
    pub recovered: Vec<Entry>,
    /// Исходы стояния: (общий, исход записей шелла).
    pub resolutions: Vec<(String, Option<String>)>,
    /// Контексты записей паузы: разбор свежести живёт здесь.
    pub pause_contexts: Vec<KillContext>,
    /// Цели, о потере терминала которых уведомили: порт `notifyBackgrounded`.
    pub backgrounded: Vec<String>,
}

impl RecordingReporter {
    pub fn recorded(&self) -> std::sync::MutexGuard<'_, Recorded> {
        self.0.lock().unwrap()
    }

    pub fn paused_pids(&self) -> Vec<i32> {
        self.recorded().paused.iter().map(|e| e.pid).collect()
    }

    pub fn resolutions(&self) -> Vec<String> {
        self.recorded()
            .resolutions
            .iter()
            .map(|(outcome, _)| outcome.clone())
            .collect()
    }
}

fn entries(processes: &[MatchedProcess], reason: &str) -> Vec<Entry> {
    processes
        .iter()
        .map(|process| Entry {
            pid: process.pid,
            target_name: process.target_name.clone(),
            reason: reason.to_string(),
            matched_by: process.matched_by,
        })
        .collect()
}

impl KillReporting for RecordingReporter {
    fn report(
        &self,
        killed: &[MatchedProcess],
        recordable: &[MatchedProcess],
        context: &KillContext,
    ) {
        let mut recorded = self.0.lock().unwrap();
        recorded.kill_reasons.push(context.reason.clone());
        recorded.kill_contexts.push(context.clone());
        recorded.killed.extend(killed.iter().map(|p| p.pid));
        recorded.recordable.extend(recordable.iter().map(|p| p.pid));
    }

    fn episode_finished(&self, _context: &KillContext) {
        self.0.lock().unwrap().finished += 1;
    }

    fn paused(&self, stopped: &[MatchedProcess], context: &KillContext) {
        let mut recorded = self.0.lock().unwrap();
        recorded.paused.extend(entries(stopped, &context.reason));
        recorded.pause_contexts.push(context.clone());
    }

    fn recovered(&self, standing: &[RecoveredProcess], context: &KillContext) {
        let processes: Vec<MatchedProcess> = standing
            .iter()
            .map(|recovered| recovered.process.clone())
            .collect();
        let mut recorded = self.0.lock().unwrap();
        recorded
            .recovered
            .extend(entries(&processes, &context.reason));
        recorded.pause_contexts.push(context.clone());
    }

    fn pause_resolved(&self, outcome: &str, shell_outcome: Option<&str>, _context: &KillContext) {
        self.0
            .lock()
            .unwrap()
            .resolutions
            .push((outcome.to_string(), shell_outcome.map(str::to_string)));
    }

    fn backgrounded(&self, target_name: &str) {
        self.0
            .lock()
            .unwrap()
            .backgrounded
            .push(target_name.to_string());
    }
}

// --- сборка -----------------------------------------------------------------

pub struct Harness {
    pub controller: GuardController,
    pub network: FakeNetwork,
    pub geo: FakeGeo,
    pub settings: FakeSettings,
    pub world: World,
    pub reporter: RecordingReporter,
    pub checks: RecordingChecks,
    pub ledger_path: std::path::PathBuf,
    /// Каталог живёт ровно столько, сколько стенд: учёт остановленных пишется
    /// настоящим файлом, а не выдумкой.
    _home: tempfile::TempDir,
}

impl Harness {
    /// Процессы по умолчанию: цель `nano` и живой VPN-клиент. Без клиента
    /// локальное основание — «приложение не запущено», и до гео дело не дойдёт.
    pub fn default_world() -> Vec<ProcessSnapshot> {
        vec![
            ProcessSnapshot {
                pid: 42,
                parent_pid: 1,
                executable_path: "/usr/bin/nano".to_string(),
                arguments: Some(vec!["nano".to_string()]),
                ..ProcessSnapshot::default()
            },
            ProcessSnapshot {
                pid: 77,
                parent_pid: 1,
                executable_path: "/usr/bin/happ".to_string(),
                arguments: Some(vec!["happ".to_string()]),
                ..ProcessSnapshot::default()
            },
        ]
    }
}

/// Без окна коалесценции: почти всем случаям оно только мешает, а проверяется
/// оно отдельным тестом.
pub fn harness() -> Harness {
    build(
        std::time::Duration::ZERO,
        FakeSettings::armed(),
        World::of(Harness::default_world()),
        &[],
    )
}

pub fn harness_with_window(window: std::time::Duration) -> Harness {
    build(
        window,
        FakeSettings::armed(),
        World::of(Harness::default_world()),
        &[],
    )
}

/// Стенд со своим миром процессов и своим учётом остановленных.
pub fn build(
    window: std::time::Duration,
    settings: FakeSettings,
    world: World,
    ledger: &[weto_config::stopped::StoppedProcess],
) -> Harness {
    let home = tempfile::tempdir().expect("временный каталог");
    let ledger_path = home.path().join("stopped.json");
    if !ledger.is_empty() {
        let mut store = weto_config::stopped::StoppedLedger::default();
        store.add(ledger);
        store.save(&ledger_path).expect("учёт записался");
    }
    build_over(window, settings, world, home, ledger_path)
}

/// Стенд поверх испорченного файла учёта. Отдельной сборкой, потому что учёт
/// читается границей один раз — при создании: подложить сломанный файл позже
/// значило бы проверять не тот случай.
pub fn build_with_broken_ledger(settings: FakeSettings, world: World) -> Harness {
    let home = tempfile::tempdir().expect("временный каталог");
    let ledger_path = home.path().join("stopped.json");
    std::fs::write(&ledger_path, "{ это не json").expect("файл записался");
    build_over(
        std::time::Duration::ZERO,
        settings,
        world,
        home,
        ledger_path,
    )
}

fn build_over(
    window: std::time::Duration,
    settings: FakeSettings,
    world: World,
    home: tempfile::TempDir,
    ledger_path: std::path::PathBuf,
) -> Harness {
    let network = FakeNetwork::healthy_tunnel();
    let geo = FakeGeo::safe();
    let reporter = RecordingReporter::default();
    let checks = RecordingChecks::default();

    let controller = GuardController::new(
        Box::new(network.clone()),
        Box::new(geo.clone()),
        Box::new(NoSecret),
        Box::new(settings.clone()),
        ProcessEnforcer::new(
            Box::new(world.clone()),
            Box::new(world.clone()),
            ledger_path.clone(),
        ),
        Box::new(reporter.clone()),
        Box::new(checks.clone()),
    )
    .with_coalesce_window(window);

    Harness {
        controller,
        network,
        geo,
        settings,
        world,
        reporter,
        checks,
        ledger_path,
        _home: home,
    }
}

/// Процесс с терминалом: группа и передняя группа tty задаются явно.
pub fn process(
    pid: i32,
    parent_pid: i32,
    executable_path: &str,
    process_group: i32,
    terminal_foreground_group: i32,
) -> ProcessSnapshot {
    ProcessSnapshot {
        pid,
        parent_pid,
        executable_path: executable_path.to_string(),
        arguments: Some(vec![executable_path.to_string()]),
        process_group,
        terminal_foreground_group,
        is_stopped: false,
    }
}

/// Процесс без управляющего терминала: демон или GUI.
pub fn detached(pid: i32, parent_pid: i32, executable_path: &str) -> ProcessSnapshot {
    process(pid, parent_pid, executable_path, 0, 0)
}
