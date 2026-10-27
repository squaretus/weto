//! `weto run` — охрана на переднем плане: для сервиса и для отладки.
//!
//! Охрана та же, что у приложения с окном: `weto_guard::runtime` — цикл,
//! писатели журналов, сборка на настоящих границах. Своё у терминальной
//! версии — замок единственного экземпляра, отказ при запущенном приложении,
//! сигналы вместо кнопок, файл статуса и лог вместо окна и уведомлений,
//! суточная проверка обновлений вместо баннера.

use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::path::Path;
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use weto_config::checks::CheckLog;
use weto_config::journal::Journal;
use weto_config::paths::Paths;
use weto_core::guard_machine::GuardPhase;
use weto_core::presentation::explanation;
use weto_guard::controller::GuardController;
use weto_guard::runtime::{spawn_guard, system_controller, CheckWriter, JournalWriter};
use weto_sys::network_events::{NetlinkEventSource, NetworkEventSourcing};
use weto_sys::process_registry::{ProcRegistry, ProcessRegistryReading};

use crate::commands::{FAILURE, OK};
use crate::context::Identity;
use crate::log::{stdout_sink, LogNotifier, LogSink, LoggingReporter};
use crate::status;
use crate::store::{Reload, WatchedSettings, WatchedSource};
use crate::update::{self, HttpReleases, ReleaseFetching, UpdateWatch};

/// Как часто писать статус, когда фаза не меняется. Под паузой такт идёт
/// раз в 250 мс — писать файл четыре раза в секунду незачем.
const STATUS_INTERVAL: Duration = Duration::from_secs(1);

pub const ALREADY_RUNNING: &str = "охрана уже запущена";
pub const APP_IS_RUNNING: &str = "запущено приложение Weto: две охраны над одними целями мешают \
     друг другу — закройте приложение";

// --- замок -----------------------------------------------------------------

/// Замок единственного экземпляра: `flock` на `run.lock`. Держится, пока жив
/// дескриптор, и отпускается ядром даже при SIGKILL — устаревшего замка
/// не бывает. В файле — pid держателя, чтобы второму было что назвать.
pub struct RunLock {
    file: File,
}

pub enum LockError {
    Held(Option<i32>),
    Io(std::io::Error),
}

impl RunLock {
    pub fn acquire(path: &Path) -> Result<RunLock, LockError> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(LockError::Io)?;
        }
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(path)
            .map_err(LockError::Io)?;
        // SAFETY: flock над своим открытым дескриптором.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::EWOULDBLOCK) {
                let mut text = String::new();
                let _ = file.read_to_string(&mut text);
                return Err(LockError::Held(text.trim().parse().ok()));
            }
            return Err(LockError::Io(error));
        }
        file.set_len(0).map_err(LockError::Io)?;
        file.rewind().map_err(LockError::Io)?;
        write!(file, "{}", std::process::id()).map_err(LockError::Io)?;
        file.flush().map_err(LockError::Io)?;
        Ok(RunLock { file })
    }
}

impl Drop for RunLock {
    fn drop(&mut self) {
        // Замок отпустит и закрытие, но pid уходящего держателя в файле
        // оставлять незачем.
        let _ = self.file.set_len(0);
    }
}

// --- приложение рядом --------------------------------------------------------

/// Каталог установки приложения с окном у любого пользователя.
const ANY_APP_DIR: &str = "/.local/share/weto/";

/// Запущено ли приложение Weto: процесс, чей бинарник лежит под каталогом
/// данных приложения (`~/.local/share/weto/<версия>/weto`). Две охраны над
/// одними целями дерутся SIGSTOP/SIGCONT, и останавливается вторая — эта.
///
/// Охрана от root стережёт цели всех пользователей, поэтому и приложение
/// ищется у всех: под любым `*/.local/share/weto/`, а не только под своим
/// каталогом. Не-root чужих `/proc/<pid>/exe` не прочтёт вовсе, и для него
/// это тот же вопрос про свой каталог (с учётом `XDG_DATA_HOME`).
pub fn app_is_running(
    registry: &dyn ProcessRegistryReading,
    app_data_dir: &Path,
    own_pid: i32,
) -> Option<i32> {
    let prefix = format!("{}/", app_data_dir.to_string_lossy().trim_end_matches('/'));
    registry
        .snapshot()
        .into_iter()
        .find(|process| {
            process.pid != own_pid
                && (process.executable_path.starts_with(&prefix)
                    || process.executable_path.contains(ANY_APP_DIR))
        })
        .map(|process| process.pid)
}

// --- сигналы ---------------------------------------------------------------

/// Пишущий конец канала сигналов. Обработчик сигнала только пишет в него байт —
/// это async-signal-safe, а всё остальное делает главный поток.
static SIGNAL_WRITE: AtomicI32 = AtomicI32::new(-1);

extern "C" fn on_signal(signal: libc::c_int) {
    let fd = SIGNAL_WRITE.load(Ordering::Relaxed);
    if fd >= 0 {
        let byte = signal as u8;
        // SAFETY: write(2) async-signal-safe; ошибку (полный канал) глотаем —
        // такой же сигнал уже ждёт своей очереди.
        unsafe {
            libc::write(fd, (&byte as *const u8).cast(), 1);
        }
    }
}

/// Канал сигналов («self-pipe»): поток охраны сигналами не прерывается,
/// главный поток ждёт их чтением.
pub struct SignalPipe {
    read: RawFd,
}

impl SignalPipe {
    pub fn install(signals: &[libc::c_int]) -> std::io::Result<SignalPipe> {
        let mut fds = [0 as libc::c_int; 2];
        // SAFETY: pipe2 заполняет массив из двух дескрипторов.
        if unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
        // Пишущий конец неблокирующий: обработчик сигнала ждать не вправе.
        // SAFETY: fcntl над только что созданным дескриптором.
        unsafe {
            let flags = libc::fcntl(fds[1], libc::F_GETFL);
            libc::fcntl(fds[1], libc::F_SETFL, flags | libc::O_NONBLOCK);
        }
        SIGNAL_WRITE.store(fds[1], Ordering::Relaxed);
        for &signal in signals {
            // SAFETY: обработчик — extern "C" функция без состояния, маска пуста.
            unsafe {
                let mut action: libc::sigaction = std::mem::zeroed();
                action.sa_sigaction = on_signal as extern "C" fn(libc::c_int) as libc::sighandler_t;
                action.sa_flags = libc::SA_RESTART;
                libc::sigemptyset(&mut action.sa_mask);
                if libc::sigaction(signal, &action, std::ptr::null_mut()) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
            }
        }
        Ok(SignalPipe { read: fds[0] })
    }

    /// Следующий сигнал. Блокируется до его прихода.
    pub fn wait(&self) -> Option<libc::c_int> {
        let mut byte = 0u8;
        loop {
            // SAFETY: читаем один байт в свою переменную.
            let read = unsafe { libc::read(self.read, (&mut byte as *mut u8).cast(), 1) };
            if read == 1 {
                return Some(byte as libc::c_int);
            }
            if read < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted
            {
                continue;
            }
            return None;
        }
    }
}

// --- события ---------------------------------------------------------------

/// События для цикла охраны: события сети плюс пробуждение от главного потока.
///
/// Без пробуждения штатный выход ждал бы конца шага такта; с ним поток
/// охраны выходит сразу, и главный дожидается его, прежде чем убрать файл
/// статуса. Сеть пересылается своим потоком: netlink недоступен — пересылка
/// просто кончается, а канал жив, пока жив главный поток.
struct WakeableEvents(Mutex<Option<Receiver<()>>>);

impl NetworkEventSourcing for WakeableEvents {
    fn subscribe(&self) -> Receiver<()> {
        self.0
            .lock()
            .expect("события охраны")
            .take()
            .unwrap_or_else(|| channel().1)
    }
}

fn wakeable_events() -> (WakeableEvents, Sender<()>) {
    let (sender, receiver) = channel();
    let network = NetlinkEventSource.subscribe();
    let forward = sender.clone();
    let _ = std::thread::Builder::new()
        .name("weto-events".to_string())
        .spawn(move || {
            while network.recv().is_ok() {
                if forward.send(()).is_err() {
                    break;
                }
            }
        });
    (WakeableEvents(Mutex::new(Some(receiver))), sender)
}

// --- статус после прохода ----------------------------------------------------

/// Что делается после каждого такта: перечитать настройки, если файл менялся,
/// записать статус, назвать в логе смену фазы.
pub struct AfterPass {
    pub controller: Arc<GuardController>,
    pub settings: Arc<WatchedSettings>,
    pub status_path: std::path::PathBuf,
    pub pid: i32,
    pub log: LogSink,
    /// Новая версия от суточной проверки — в статус как `updateAvailable`.
    pub update_available: Arc<Mutex<Option<String>>>,
    last_written: Option<SystemTime>,
    last_phase: Option<String>,
}

impl AfterPass {
    pub fn new(
        controller: Arc<GuardController>,
        settings: Arc<WatchedSettings>,
        status_path: std::path::PathBuf,
        pid: i32,
        log: LogSink,
    ) -> AfterPass {
        AfterPass {
            controller,
            settings,
            status_path,
            pid,
            log,
            update_available: Arc::new(Mutex::new(None)),
            last_written: None,
            last_phase: None,
        }
    }

    pub fn pass(&mut self, phase: &GuardPhase, now: SystemTime) {
        match self.settings.reload_if_changed() {
            Reload::Unchanged => {}
            Reload::Reloaded => (self.log)("настройки перечитаны"),
            Reload::Failed(error) => (self.log)(&format!(
                "настройки не перечитаны, охрана на прежних: {error}"
            )),
        }

        // Смена фазы — по заголовку и улике: «На страже» с новой страной
        // тоже новость, а такт без новостей лог не засоряет.
        let text = explanation(phase, self.controller.remaining_pause());
        let summary = format!(
            "{} — {}: {}",
            text.title,
            status::lowercase_first(&text.action),
            text.evidence
        );
        let changed = self.last_phase.as_deref() != Some(summary.as_str());
        if changed {
            (self.log)(&summary);
            self.last_phase = Some(summary);
        }

        let due = self
            .last_written
            .is_none_or(|at| now.duration_since(at).unwrap_or(Duration::ZERO) >= STATUS_INTERVAL);
        if changed || due {
            let snapshot = self.controller.snapshot();
            let update = self.update_available.lock().expect("обновление").clone();
            let file = status::build(&snapshot, &self.settings.current(), self.pid, now, update);
            if let Err(error) = status::write(&self.status_path, &file) {
                (self.log)(&format!("статус не записался: {error}"));
            }
            self.last_written = Some(now);
        }
    }
}

// --- обновление ----------------------------------------------------------------

/// Суточная проверка релизов в работающей охране: через минуту после старта
/// и раз в сутки. Сама охрана ничего не ставит — называет версию в логе
/// и в статусе, ставит `weto update`. Сборка без версии не проверяет ничего:
/// сравнивать не с чем.
pub fn spawn_update_watch(
    version: &str,
    fetcher: Box<dyn ReleaseFetching>,
    available: Arc<Mutex<Option<String>>>,
    log: LogSink,
) {
    let Some(current) = update::known_version(version) else {
        return;
    };
    let _ = std::thread::Builder::new()
        .name("weto-update".to_string())
        .spawn(move || {
            let mut watch = UpdateWatch::new();
            std::thread::sleep(update::FIRST_CHECK_DELAY);
            loop {
                let result = update::check(fetcher.as_ref(), current);
                if let Some(line) = watch.record(result, SystemTime::now()) {
                    log(&line);
                }
                *available.lock().expect("обновление") = watch.available();
                std::thread::sleep(update::CHECK_INTERVAL);
            }
        });
}

// --- run ---------------------------------------------------------------------

/// Чью охрану ведёт этот процесс — первым словом строки старта.
pub fn scope_text(identity: &Identity) -> String {
    if identity.is_root {
        "вся машина".to_string()
    } else {
        format!("пользователь {}", identity.user)
    }
}

pub fn run(paths: &Paths, app_data_dir: &Path, version: &str, identity: &Identity) -> i32 {
    let log = stdout_sink();
    let pid = std::process::id() as i32;

    let _lock = match RunLock::acquire(&paths.run_lock_file()) {
        Ok(lock) => lock,
        Err(LockError::Held(Some(holder))) => {
            eprintln!("{ALREADY_RUNNING} (pid {holder})");
            return FAILURE;
        }
        Err(LockError::Held(None)) => {
            eprintln!("{ALREADY_RUNNING}");
            return FAILURE;
        }
        Err(LockError::Io(error)) => {
            eprintln!(
                "не взять замок {}: {error}",
                paths.run_lock_file().display()
            );
            return FAILURE;
        }
    };

    if let Some(app) = app_is_running(&ProcRegistry::new(), app_data_dir, pid) {
        eprintln!("{APP_IS_RUNNING} (pid {app})");
        return FAILURE;
    }

    let settings = match WatchedSettings::open(paths.settings_file()) {
        Ok(settings) => settings,
        Err(error) => {
            eprintln!("{error}");
            return FAILURE;
        }
    };

    // Сигналы — раньше охраны: SIGTERM, пришедший в первую же секунду,
    // обязан пройти штатным выходом, а не убить процесс посреди восстановления.
    let signals = match SignalPipe::install(&[libc::SIGTERM, libc::SIGINT, libc::SIGUSR1]) {
        Ok(signals) => signals,
        Err(error) => {
            eprintln!("не перехватить сигналы: {error}");
            return FAILURE;
        }
    };

    let journal = Arc::new(Mutex::new(Journal::load(&paths.journal_file())));
    let checks = Arc::new(Mutex::new(CheckLog::load(&paths.checks_file())));
    let writer = JournalWriter::new(paths.clone(), journal, Box::new(LogNotifier(log.clone())));
    let controller = Arc::new(system_controller(
        paths,
        Box::new(WatchedSource(settings.clone())),
        Box::new(LoggingReporter {
            inner: writer,
            log: log.clone(),
        }),
        Box::new(CheckWriter::new(paths.clone(), checks)),
    ));

    log(&format!(
        "охрана запущена (pid {pid}, {}); weto {version}; настройки: {}",
        scope_text(identity),
        paths.settings_file().display()
    ));

    let (events, wake) = wakeable_events();
    let mut after = AfterPass::new(
        controller.clone(),
        settings,
        paths.status_file(),
        pid,
        log.clone(),
    );
    spawn_update_watch(
        version,
        Box::new(HttpReleases::new()),
        after.update_available.clone(),
        log.clone(),
    );
    let guard = spawn_guard(controller.clone(), Box::new(events), move |phase| {
        after.pass(phase, SystemTime::now())
    });

    loop {
        match signals.wait() {
            Some(libc::SIGUSR1) => {
                // Та же проверка, что по кнопке: повод «нажатие» в журнале
                // проверок. Проход идёт здесь, проба — своей дорожкой.
                log("проверка подключения по запросу");
                controller.probe_now();
            }
            Some(signal) => {
                let name = if signal == libc::SIGINT {
                    "SIGINT"
                } else {
                    "SIGTERM"
                };
                log(&format!(
                    "{name}: штатный выход — стоящие цели продолжаются"
                ));
                break;
            }
            None => {
                log("канал сигналов закрылся — штатный выход");
                break;
            }
        }
    }

    // Тот же выход, что у приложения: SIGCONT стоящим, исход эпизода,
    // учёт — следующему запуску, если наблюдать уже нечем.
    controller.shutdown();
    let _ = wake.send(());
    let _ = guard.join();
    let _ = std::fs::remove_file(paths.status_file());
    log("охрана остановлена");
    OK
}
