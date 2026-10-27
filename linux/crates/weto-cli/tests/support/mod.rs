//! Стенд команд: настоящее хранилище во временном `$HOME`, подменённые
//! границы — сеть, гео, таблица процессов, сигналы, внешние команды и часы.

#![allow(dead_code)]

use std::io::Cursor;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use weto_cli::commands::Io;
use weto_cli::context::{Clock, Context, Identity, InterfaceListing, ProcessControl};
use weto_cli::service::{CommandOutput, CommandRunning};
use weto_cli::update::{BinaryFiles, FetchError, ReleaseFetching};
use weto_cli::user_path::UserPathLookup;
use weto_config::paths::Paths;
use weto_config::settings::Settings;
use weto_core::geo::{ConfirmSource, GeoProbeReport, SourceOutcome};
use weto_core::network::{NetworkSnapshot, OutgoingRoute};
use weto_core::process::ProcessSnapshot;
use weto_sys::geo_probe::GeoProbing;
use weto_sys::network_snapshot::NetworkSnapshotReading;
use weto_sys::process_registry::ProcessRegistryReading;

// --- сеть ---------------------------------------------------------------------

#[derive(Clone)]
pub struct FakeNetwork(pub Arc<Mutex<NetworkSnapshot>>);

impl FakeNetwork {
    /// Трафик идёт через `eth0`, туннеля нет.
    pub fn direct() -> FakeNetwork {
        FakeNetwork(Arc::new(Mutex::new(NetworkSnapshot {
            outgoing: Some(OutgoingRoute {
                interface: "eth0".to_string(),
                address: "192.168.1.10".to_string(),
            }),
            up_interfaces: vec!["lo".to_string(), "eth0".to_string()],
        })))
    }

    /// `wg0` поднят и несёт трафик.
    pub fn tunnel() -> FakeNetwork {
        FakeNetwork(Arc::new(Mutex::new(NetworkSnapshot {
            outgoing: Some(OutgoingRoute {
                interface: "wg0".to_string(),
                address: "10.8.0.2".to_string(),
            }),
            up_interfaces: vec!["lo".to_string(), "eth0".to_string(), "wg0".to_string()],
        })))
    }
}

impl NetworkSnapshotReading for FakeNetwork {
    fn snapshot(&self) -> NetworkSnapshot {
        self.0.lock().unwrap().clone()
    }
}

// --- гео ----------------------------------------------------------------------

#[derive(Clone)]
pub struct FakeGeo {
    pub country: Arc<Mutex<String>>,
    pub calls: Arc<AtomicUsize>,
}

impl FakeGeo {
    pub fn reporting(country: &str) -> FakeGeo {
        FakeGeo {
            country: Arc::new(Mutex::new(country.to_string())),
            calls: Arc::new(AtomicUsize::new(0)),
        }
    }

    pub fn calls(&self) -> usize {
        self.calls.load(Ordering::SeqCst)
    }
}

impl GeoProbing for FakeGeo {
    fn probe(&self, _token: Option<&str>) -> GeoProbeReport {
        self.calls.fetch_add(1, Ordering::SeqCst);
        let country = self.country.lock().unwrap().clone();
        GeoProbeReport {
            ip: Some("203.0.113.28".to_string()),
            ipinfo: SourceOutcome::Answered(country.clone()),
            confirmation: SourceOutcome::Answered(country),
            confirm_source: Some(ConfirmSource::Freeipapi),
            has_network_path: true,
            checked_at: UNIX_EPOCH + Duration::from_secs(1_800_000_000),
            traces: Vec::new(),
        }
    }
}

// --- процессы -----------------------------------------------------------------

#[derive(Clone, Default)]
pub struct FakeRegistry(pub Arc<Mutex<Vec<ProcessSnapshot>>>);

impl FakeRegistry {
    pub fn with(processes: Vec<ProcessSnapshot>) -> FakeRegistry {
        FakeRegistry(Arc::new(Mutex::new(processes)))
    }
}

impl ProcessRegistryReading for FakeRegistry {
    fn snapshot(&self) -> Vec<ProcessSnapshot> {
        self.0.lock().unwrap().clone()
    }
}

pub fn process(pid: i32, executable_path: &str) -> ProcessSnapshot {
    ProcessSnapshot {
        pid,
        parent_pid: 1,
        executable_path: executable_path.to_string(),
        arguments: Some(vec![executable_path.to_string()]),
        ..ProcessSnapshot::default()
    }
}

/// Что делает «охрана», получив просьбу о проверке.
type CheckAnswer = Arc<Mutex<Option<Box<dyn Fn() + Send>>>>;

/// Чужие процессы: кто жив и кому ушёл SIGUSR1. Ответ на просьбу о проверке
/// задаёт тест — так он изображает охрану, переписавшую статус.
#[derive(Clone, Default)]
pub struct FakeProcesses {
    pub alive: Arc<Mutex<Vec<i32>>>,
    pub asked: Arc<Mutex<Vec<i32>>>,
    pub on_request: CheckAnswer,
}

impl FakeProcesses {
    pub fn alive(pids: &[i32]) -> FakeProcesses {
        FakeProcesses {
            alive: Arc::new(Mutex::new(pids.to_vec())),
            ..FakeProcesses::default()
        }
    }

    pub fn answers_with(&self, action: impl Fn() + Send + 'static) {
        *self.on_request.lock().unwrap() = Some(Box::new(action));
    }

    pub fn asked(&self) -> Vec<i32> {
        self.asked.lock().unwrap().clone()
    }
}

impl ProcessControl for FakeProcesses {
    fn is_alive(&self, pid: i32) -> bool {
        self.alive.lock().unwrap().contains(&pid)
    }

    fn request_check(&self, pid: i32) -> std::io::Result<()> {
        self.asked.lock().unwrap().push(pid);
        if let Some(action) = self.on_request.lock().unwrap().as_ref() {
            action();
        }
        Ok(())
    }
}

// --- внешние команды -------------------------------------------------------------

/// Внешние команды: записываются, отвечают заданным текстом.
#[derive(Clone, Default)]
pub struct FakeCommands {
    pub calls: Arc<Mutex<Vec<String>>>,
    pub answers: Arc<Mutex<Vec<(String, CommandOutput)>>>,
}

impl FakeCommands {
    /// Ответ на команду, чья строка начинается с `prefix`.
    pub fn answers(&self, prefix: &str, success: bool, stdout: &str) {
        self.answers.lock().unwrap().push((
            prefix.to_string(),
            CommandOutput {
                success,
                stdout: stdout.to_string(),
                stderr: String::new(),
            },
        ));
    }

    pub fn calls(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
    }
}

impl CommandRunning for FakeCommands {
    fn run(&self, program: &str, args: &[&str]) -> Result<CommandOutput, String> {
        let line = std::iter::once(program)
            .chain(args.iter().copied())
            .collect::<Vec<_>>()
            .join(" ");
        self.calls.lock().unwrap().push(line.clone());
        let answers = self.answers.lock().unwrap();
        Ok(answers
            .iter()
            .find(|(prefix, _)| line.starts_with(prefix.as_str()))
            .map(|(_, output)| output.clone())
            .unwrap_or(CommandOutput {
                success: true,
                stdout: String::new(),
                stderr: String::new(),
            }))
    }
}

// --- интерфейсы ------------------------------------------------------------------

/// Имена интерфейсов машины — всех, и опущенных тоже.
#[derive(Clone, Default)]
pub struct FakeInterfaces(pub Arc<Mutex<Vec<String>>>);

impl FakeInterfaces {
    pub fn set(&self, names: &[&str]) {
        *self.0.lock().unwrap() = names.iter().map(|name| name.to_string()).collect();
    }
}

impl InterfaceListing for FakeInterfaces {
    fn interfaces(&self) -> Vec<String> {
        self.0.lock().unwrap().clone()
    }
}

// --- релизы -------------------------------------------------------------------------

/// Ответ на адрес: тело или отказ.
pub type Answer = (String, Result<Vec<u8>, FetchError>);

/// Сеть обновления: ответы по адресу, запросы записываются.
#[derive(Clone, Default)]
pub struct FakeReleases {
    pub bodies: Arc<Mutex<Vec<Answer>>>,
    pub requested: Arc<Mutex<Vec<String>>>,
}

impl FakeReleases {
    pub fn answers(&self, url: &str, body: Result<Vec<u8>, FetchError>) {
        self.bodies.lock().unwrap().push((url.to_string(), body));
    }

    pub fn requested(&self) -> Vec<String> {
        self.requested.lock().unwrap().clone()
    }
}

impl ReleaseFetching for FakeReleases {
    fn fetch(&self, url: &str) -> Result<Vec<u8>, FetchError> {
        self.requested.lock().unwrap().push(url.to_string());
        self.bodies
            .lock()
            .unwrap()
            .iter()
            .find(|(known, _)| known == url)
            .map(|(_, body)| body.clone())
            .unwrap_or_else(|| Err(FetchError::Failed(format!("нет ответа для {url}"))))
    }
}

// --- бинарник -----------------------------------------------------------------------

/// Замена бинарника: куда и что записано.
pub type Replacement = (PathBuf, Vec<u8>);

/// Каталог бинарника: права задаёт тест, замена записывается.
#[derive(Clone)]
pub struct FakeBinary {
    pub writable: Arc<Mutex<bool>>,
    pub replaced: Arc<Mutex<Vec<Replacement>>>,
}

impl Default for FakeBinary {
    fn default() -> Self {
        FakeBinary {
            writable: Arc::new(Mutex::new(true)),
            replaced: Arc::new(Mutex::new(Vec::new())),
        }
    }
}

impl BinaryFiles for FakeBinary {
    fn writable(&self, _directory: &std::path::Path) -> bool {
        *self.writable.lock().unwrap()
    }

    fn replace(&self, executable: &std::path::Path, contents: &[u8]) -> std::io::Result<()> {
        self.replaced
            .lock()
            .unwrap()
            .push((executable.to_path_buf(), contents.to_vec()));
        Ok(())
    }
}

// --- PATH пользователя -------------------------------------------------------------

/// Чужой логин-шелл и база учётных записей: ответ задаёт тест, вопросы
/// записываются.
#[derive(Clone, Default)]
pub struct FakeUserPaths {
    pub path: Arc<Mutex<Option<String>>>,
    pub home: Arc<Mutex<Option<PathBuf>>>,
    pub asked: Arc<Mutex<Vec<String>>>,
}

impl FakeUserPaths {
    pub fn asked(&self) -> Vec<String> {
        self.asked.lock().unwrap().clone()
    }
}

impl UserPathLookup for FakeUserPaths {
    fn login_path(&self, user: &str) -> Option<String> {
        self.asked.lock().unwrap().push(user.to_string());
        self.path.lock().unwrap().clone()
    }

    fn home(&self, _user: &str) -> Option<PathBuf> {
        self.home.lock().unwrap().clone()
    }
}

// --- часы ---------------------------------------------------------------------

/// Часы, которые идут только по `sleep`: ожидание `check` не ждёт по-настоящему.
#[derive(Clone)]
pub struct FakeClock(pub Arc<Mutex<SystemTime>>);

impl FakeClock {
    pub fn at(moment: SystemTime) -> FakeClock {
        FakeClock(Arc::new(Mutex::new(moment)))
    }
}

impl Clock for FakeClock {
    fn now(&self) -> SystemTime {
        *self.0.lock().unwrap()
    }

    fn sleep(&self, duration: Duration) {
        *self.0.lock().unwrap() += duration;
    }
}

pub fn now() -> SystemTime {
    UNIX_EPOCH + Duration::from_secs(1_800_000_000)
}

// --- стенд --------------------------------------------------------------------

pub struct Bench {
    pub ctx: Context,
    pub network: FakeNetwork,
    pub geo: FakeGeo,
    pub registry: FakeRegistry,
    pub processes: FakeProcesses,
    pub commands: FakeCommands,
    pub clock: FakeClock,
    pub interfaces: FakeInterfaces,
    pub releases: FakeReleases,
    pub binary: FakeBinary,
    pub user_paths: FakeUserPaths,
    pub home: tempfile::TempDir,
}

pub struct Output {
    pub code: i32,
    pub out: String,
    pub err: String,
}

impl Bench {
    pub fn new() -> Bench {
        let home = tempfile::tempdir().expect("временный каталог");
        let network = FakeNetwork::direct();
        let geo = FakeGeo::reporting("KZ");
        let registry = FakeRegistry::default();
        let processes = FakeProcesses::default();
        let commands = FakeCommands::default();
        let clock = FakeClock::at(now());
        let interfaces = FakeInterfaces::default();
        interfaces.set(&["lo", "eth0"]);
        let releases = FakeReleases::default();
        let binary = FakeBinary::default();
        let user_paths = FakeUserPaths::default();
        let root = home.path().to_path_buf();
        let ctx = Context {
            paths: Paths::rooted_named(root.clone(), "weto-cli"),
            system_paths: Paths::system_under(&root.join("system")),
            app_data_dir: root.join(".local/share/weto"),
            identity: Identity {
                is_root: false,
                user: "square".to_string(),
                executable: Ok(PathBuf::from("/opt/weto/weto")),
                user_unit_dir: root.join(".config/systemd/user"),
                system_unit_dir: root.join("system/etc/systemd/system"),
            },
            network: Box::new(network.clone()),
            geo: Box::new(geo.clone()),
            registry: Box::new(registry.clone()),
            processes: Box::new(processes.clone()),
            commands: Box::new(commands.clone()),
            clock: Box::new(clock.clone()),
            interfaces: Box::new(interfaces.clone()),
            releases: Box::new(releases.clone()),
            binary: Box::new(binary.clone()),
            version: "0.2.0".to_string(),
            sudo_user: None,
            user_paths: Box::new(user_paths.clone()),
            stdin_is_tty: false,
        };
        Bench {
            ctx,
            network,
            geo,
            registry,
            processes,
            commands,
            clock,
            interfaces,
            releases,
            binary,
            user_paths,
            home,
        }
    }

    /// Команды от root: системное хранилище (`etc/weto`, `var/lib/weto` под
    /// корнем стенда) и системный юнит.
    pub fn run_by_root(mut self) -> Bench {
        self.ctx.identity.is_root = true;
        self.ctx.paths = self.ctx.system_paths.clone();
        self
    }

    /// Охрана уже установлена на всю машину: системный каталог настроек есть.
    pub fn with_system_install(self) -> Bench {
        std::fs::create_dir_all(&self.ctx.system_paths.config_dir).unwrap();
        self
    }

    pub fn run(&self, words: &[&str]) -> Output {
        self.run_with_input(words, "")
    }

    pub fn run_with_input(&self, words: &[&str], input: &str) -> Output {
        let arguments: Vec<String> = words.iter().map(|w| w.to_string()).collect();
        let mut out = Vec::new();
        let mut err = Vec::new();
        let mut input = Cursor::new(input.as_bytes().to_vec());
        let code = weto_cli::main_with(
            &arguments,
            &self.ctx,
            &mut Io {
                out: &mut out,
                err: &mut err,
                input: &mut input,
            },
        );
        Output {
            code,
            out: String::from_utf8(out).unwrap(),
            err: String::from_utf8(err).unwrap(),
        }
    }

    pub fn settings(&self) -> Settings {
        Settings::load(&self.ctx.paths.settings_file()).expect("настройки читаются")
    }

    /// Исполняемый скрипт во временном каталоге — цель, которая есть на диске.
    pub fn script(&self, name: &str) -> String {
        let path = self.home.path().join("bin").join(name);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "#!/bin/sh\nexit 0\n").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path.to_string_lossy().into_owned()
    }
}
