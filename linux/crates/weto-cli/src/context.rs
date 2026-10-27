//! Всё, с чем команды говорят снаружи процесса, — за трейтами.
//!
//! Подменяются в тестах только эти границы: сеть, гео-сервисы, таблица
//! процессов, сигналы чужому процессу, внешние команды и часы. Хранилище
//! настроек, журналов и статуса — настоящие файлы во временном `$HOME`:
//! подделывать их значило бы проверять подделку.

use std::io;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use weto_config::paths::{Paths, APP_DIR, CLI_DIR};
use weto_sys::geo_probe::{GeoEndpoints, GeoProbing, HttpGeoProbe, RouteNetworkPath};
use weto_sys::network_snapshot::{KernelNetworkReader, NetworkSnapshotReading};
use weto_sys::process_registry::{ProcRegistry, ProcessRegistryReading};

use crate::service::{CommandRunning, SystemCommands, UNIT_NAME};
use crate::update::{BinaryFiles, DiskBinary, HttpReleases, ReleaseFetching};
use crate::user_path::{LoginShellPaths, UserPathLookup};

/// Чужой процесс: жив ли он и просьба проверить подключение.
pub trait ProcessControl: Send + Sync {
    fn is_alive(&self, pid: i32) -> bool;
    /// `SIGUSR1` работающей охране: «проверь подключение сейчас».
    fn request_check(&self, pid: i32) -> io::Result<()>;
}

pub struct KernelProcesses;

impl ProcessControl for KernelProcesses {
    /// `kill(pid, 0)`: сигнала нет, есть только проверка. `EPERM` — процесс
    /// жив, но чужой (охрана, поднятая root-сервисом), и это тоже «жив».
    fn is_alive(&self, pid: i32) -> bool {
        if pid <= 0 {
            return false;
        }
        // SAFETY: нулевой сигнал не доставляется, ядро лишь проверяет pid.
        let answer = unsafe { libc::kill(pid, 0) };
        answer == 0 || io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
    }

    fn request_check(&self, pid: i32) -> io::Result<()> {
        // SAFETY: обычный kill(2) с числом сигнала из libc.
        if unsafe { libc::kill(pid, libc::SIGUSR1) } == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }
}

/// Часы и ожидание: `check` ждёт до 15 с, и тест не обязан ждать вместе с ним.
pub trait Clock: Send + Sync {
    fn now(&self) -> SystemTime;
    fn sleep(&self, duration: Duration);
}

pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> SystemTime {
        SystemTime::now()
    }

    fn sleep(&self, duration: Duration) {
        std::thread::sleep(duration);
    }
}

/// Имена сетевых интерфейсов машины — всех, а не только поднятых: `vpn set wg0`
/// узнаёт туннель по имени, даже когда тот сейчас опущен.
pub trait InterfaceListing: Send + Sync {
    fn interfaces(&self) -> Vec<String>;
}

pub struct KernelInterfaces;

impl InterfaceListing for KernelInterfaces {
    fn interfaces(&self) -> Vec<String> {
        let mut names = Vec::new();
        // SAFETY: if_nameindex отдаёт массив, кончающийся нулевой записью;
        // имена копируются до if_freenameindex, указатели не хранятся.
        unsafe {
            let list = libc::if_nameindex();
            if list.is_null() {
                return names;
            }
            let mut entry = list;
            while (*entry).if_index != 0 && !(*entry).if_name.is_null() {
                names.push(
                    std::ffi::CStr::from_ptr((*entry).if_name)
                        .to_string_lossy()
                        .into_owned(),
                );
                entry = entry.add(1);
            }
            libc::if_freenameindex(list);
        }
        names
    }
}

/// Кто запускает команду и откуда: от этого зависит, куда ляжет юнит systemd.
#[derive(Debug, Clone)]
pub struct Identity {
    pub is_root: bool,
    pub user: String,
    /// Абсолютный путь бинарника после разворота симлинков — то, что сервис
    /// будет запускать.
    pub executable: Result<PathBuf, String>,
    /// Каталог пользовательских юнитов (`$XDG_CONFIG_HOME/systemd/user`).
    pub user_unit_dir: PathBuf,
    /// Каталог системных юнитов (`/etc/systemd/system`).
    pub system_unit_dir: PathBuf,
}

impl Identity {
    pub fn from_env() -> Identity {
        let config_home = Paths::from_env_named(CLI_DIR)
            .config_dir
            .parent()
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/tmp"));
        Identity {
            // SAFETY: geteuid не имеет побочных эффектов и не падает.
            is_root: unsafe { libc::geteuid() } == 0,
            user: user_name(),
            executable: std::env::current_exe()
                .and_then(|path| path.canonicalize())
                .map_err(|error| error.to_string()),
            user_unit_dir: config_home.join("systemd/user"),
            system_unit_dir: PathBuf::from("/etc/systemd/system"),
        }
    }
}

/// Имя пользователя: `$USER`, а без него — из базы учётных записей.
fn user_name() -> String {
    if let Some(user) = std::env::var_os("USER").filter(|value| !value.is_empty()) {
        return user.to_string_lossy().into_owned();
    }
    // SAFETY: getpwuid возвращает указатель на статическую запись или NULL;
    // читаем имя сразу и не храним указатель.
    unsafe {
        let entry = libc::getpwuid(libc::geteuid());
        if entry.is_null() || (*entry).pw_name.is_null() {
            return String::new();
        }
        std::ffi::CStr::from_ptr((*entry).pw_name)
            .to_string_lossy()
            .into_owned()
    }
}

pub struct Context {
    /// Хранилище этого запуска: от root — системное (`/etc/weto`,
    /// `/var/lib/weto`), иначе пользовательское (`~/.config/weto-cli`,
    /// `~/.local/state/weto-cli`). Выбрано эффективным uid, не `$HOME`.
    pub paths: Paths,
    /// Системное хранилище — всегда, и для не-root тоже: при системной
    /// установке `status` читает его файл статуса.
    pub system_paths: Paths,
    /// Каталог данных приложения с окном (`~/.local/share/weto`): процесс,
    /// чей бинарник лежит под ним, — запущенное приложение Weto.
    pub app_data_dir: PathBuf,
    pub identity: Identity,
    pub network: Box<dyn NetworkSnapshotReading>,
    pub geo: Box<dyn GeoProbing>,
    pub registry: Box<dyn ProcessRegistryReading>,
    pub processes: Box<dyn ProcessControl>,
    pub commands: Box<dyn CommandRunning>,
    pub clock: Box<dyn Clock>,
    pub interfaces: Box<dyn InterfaceListing>,
    pub releases: Box<dyn ReleaseFetching>,
    pub binary: Box<dyn BinaryFiles>,
    /// Своя версия — та, что вшита сборкой (`WETO_VERSION`).
    pub version: String,
    /// Кто вызвал `sudo` (`SUDO_USER`, не root): голое имя цели, не найденное
    /// у root, ищется в его `PATH`.
    pub sudo_user: Option<String>,
    pub user_paths: Box<dyn UserPathLookup>,
    /// Ввод — терминал: `token set` без аргумента подсказывает, чего ждёт.
    pub stdin_is_tty: bool,
}

impl Context {
    /// Настоящая система.
    pub fn from_env() -> Context {
        let identity = Identity::from_env();
        Context {
            paths: if identity.is_root {
                Paths::system()
            } else {
                Paths::from_env_named(CLI_DIR)
            },
            system_paths: Paths::system(),
            app_data_dir: Paths::from_env_named(APP_DIR).data_dir,
            identity,
            network: Box::new(KernelNetworkReader::new()),
            geo: Box::new(HttpGeoProbe::new(
                GeoEndpoints::default(),
                Box::new(RouteNetworkPath),
            )),
            registry: Box::new(ProcRegistry::new()),
            processes: Box::new(KernelProcesses),
            commands: Box::new(SystemCommands),
            clock: Box::new(SystemClock),
            interfaces: Box::new(KernelInterfaces),
            releases: Box::new(HttpReleases::new()),
            binary: Box::new(DiskBinary),
            version: crate::version().to_string(),
            sudo_user: std::env::var("SUDO_USER")
                .ok()
                .filter(|user| !user.is_empty() && user != "root"),
            user_paths: Box::new(LoginShellPaths),
            // SAFETY: isatty только спрашивает про дескриптор.
            stdin_is_tty: unsafe { libc::isatty(0) } == 1,
        }
    }

    /// Охрана установлена на всю машину, а команду дал не root: настройки,
    /// журналы и токен его — root, и в своё пользовательское хранилище
    /// команде писать нельзя: охрана его не читает. Признак — системный
    /// каталог настроек или системный юнит.
    pub fn system_install_seen_by_user(&self) -> bool {
        !self.identity.is_root
            && (self.system_paths.config_dir.exists()
                || self.identity.system_unit_dir.join(UNIT_NAME).exists())
    }

    /// Файл статуса, который читают `status` и `check`: у не-root при
    /// системной установке — системный (`0644`, читается без sudo).
    pub fn status_file(&self) -> PathBuf {
        if self.system_install_seen_by_user() {
            self.system_paths.status_file()
        } else {
            self.paths.status_file()
        }
    }
}

/// Системное хранилище под root: каталоги `0755` — статус `0644` обязан
/// читаться без sudo. Создаются только командами, которые пишут: каталог
/// `/etc/weto` — признак системной установки, и `sudo weto version` его
/// заводить не вправе.
pub fn prepare_system_storage(paths: &Paths) -> io::Result<()> {
    create_public_dir(&paths.config_dir)?;
    create_public_dir(&paths.state_dir)
}

/// Под root всё, что создаст процесс, — только для root (umask `077`):
/// журналы, учёт и замок выходят `0600`. Настройки и статус получают `0644`
/// явно, токен — `0600` сам.
pub fn restrict_umask() {
    // SAFETY: umask меняет только маску процесса и не падает.
    unsafe {
        libc::umask(0o077);
    }
}

/// Каталог `0755`. Существующий не трогается: права на нём выставил
/// администратор, и спорить с ним незачем.
pub fn create_public_dir(directory: &Path) -> io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    if directory.is_dir() {
        return Ok(());
    }
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o755)
        .create(directory)?;
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o755))
}
