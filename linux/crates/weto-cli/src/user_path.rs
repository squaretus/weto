//! Голое имя цели под `sudo` ищется по `PATH` того, кто вызвал `sudo`.
//!
//! Под root `weto target add claude` искал бы `claude` по `PATH` root, а он
//! стоит в `~/.local/bin` пользователя: цель не находилась, и охрана всей
//! машины её не видела. Поэтому, когда процесс идёт от root и задан
//! `SUDO_USER` (не root), имя, не найденное у root, ищется у пользователя:
//! сперва по `PATH` его логин-шелла, затем в общепринятых каталогах его
//! домашнего. Найденное записывается абсолютным путём **без разворота
//! симлинков**: симлинк переживает обновление цели, а разворачивает его охрана
//! при каждом разрешении. То же правило — на macOS.

use std::io::Read;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// Сколько ждать логин-шелл пользователя: профиль с сетевыми вызовами или
/// просьбой ввода иначе повесил бы команду.
pub const LOGIN_SHELL_TIMEOUT: Duration = Duration::from_secs(3);

/// Каталоги в домашнем, куда ставятся инструменты помимо пакетного менеджера.
/// Спрашиваются, когда шелл не ответил или в его `PATH` имени нет.
pub const HOME_DIRECTORIES: [&str; 6] = [
    ".local/bin",
    "bin",
    ".cargo/bin",
    ".bun/bin",
    ".deno/bin",
    ".npm-global/bin",
];

/// «PATH пользователя по имени» — граница системы: чужой логин-шелл
/// и база учётных записей. В тестах подменяется.
pub trait UserPathLookup: Send + Sync {
    /// `PATH` логин-шелла пользователя или `None`, если шелл не ответил.
    fn login_path(&self, user: &str) -> Option<String>;
    /// Домашний каталог из базы учётных записей.
    fn home(&self, user: &str) -> Option<PathBuf>;
}

/// Настоящая система: `runuser -l` (а без него — `su -l`) от root, без
/// интерактивного ввода. Шелл берётся из базы учётных записей — так делает
/// сам `-l`.
pub struct LoginShellPaths;

impl UserPathLookup for LoginShellPaths {
    fn login_path(&self, user: &str) -> Option<String> {
        ["runuser", "su"]
            .into_iter()
            .find_map(|program| login_shell_path(program, user))
    }

    fn home(&self, user: &str) -> Option<PathBuf> {
        let name = std::ffi::CString::new(user).ok()?;
        // SAFETY: getpwnam возвращает указатель на статическую запись или NULL;
        // каталог копируется сразу, указатель не хранится.
        unsafe {
            let entry = libc::getpwnam(name.as_ptr());
            if entry.is_null() || (*entry).pw_dir.is_null() {
                return None;
            }
            let dir = std::ffi::CStr::from_ptr((*entry).pw_dir);
            Some(PathBuf::from(dir.to_string_lossy().into_owned()))
        }
    }
}

/// `PATH` логин-шелла через `program -l user -c …`. Профиль может что-то
/// напечатать раньше — берётся последняя строка вывода.
fn login_shell_path(program: &str, user: &str) -> Option<String> {
    let mut child = Command::new(program)
        .args(["-l", user, "-c", "printf %s \"$PATH\""])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => break,
            Ok(Some(_)) | Err(_) => return None,
            Ok(None) if started.elapsed() >= LOGIN_SHELL_TIMEOUT => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(20)),
        }
    }
    let mut output = String::new();
    child.stdout.take()?.read_to_string(&mut output).ok()?;
    let path = output.rsplit('\n').next().unwrap_or("").trim().to_string();
    (!path.is_empty()).then_some(path)
}

/// Исполняемый файл — не каталог и с битом исполнения.
fn is_executable(path: &Path) -> bool {
    std::fs::metadata(path)
        .map(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

/// Где у пользователя лежит команда: первый исполняемый файл с этим именем
/// в `PATH` его логин-шелла, затем в каталогах домашнего. Путь — как он лежит
/// в каталоге, без разворота симлинков.
pub fn find_for_user(lookup: &dyn UserPathLookup, user: &str, name: &str) -> Option<PathBuf> {
    if name.is_empty() || name.contains('/') {
        return None;
    }
    let from_shell = lookup.login_path(user).and_then(|path| {
        std::env::split_paths(&path)
            .filter(|directory| directory.is_absolute())
            .map(|directory| directory.join(name))
            .find(|candidate| is_executable(candidate))
    });
    from_shell.or_else(|| {
        let home = lookup.home(user)?;
        HOME_DIRECTORIES
            .iter()
            .map(|directory| home.join(directory).join(name))
            .find(|candidate| is_executable(candidate))
    })
}

/// Третья строка вывода, когда цель нашлась у пользователя.
pub fn found_text(user: &str, path: &Path) -> String {
    format!("найдено в PATH пользователя {user}: {}", path.display())
}
