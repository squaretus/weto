//! Вернуть цель на передний план её терминала, введя `fg` в её шелл.
//!
//! Порт `macos/Sources/WetoSystem/TerminalForegroundReturner.swift`. Снаружи сессии терминал
//! не отдать: `tcsetpgrp` требует быть в этой сессии, а `TIOCSTI` не от root запрещён и с ядра
//! 6.2 закрыт вовсе. Остаётся ввод через того, кто терминал ведёт. AppleScript на Linux нет,
//! поэтому путь один — tmux, он же единственный, под кем шелл и забирает терминал у стоящей цели.
//! Вне tmux — честный отказ, дальше кнопка и окно терминала с подсказкой.
//!
//! Вызывать только когда шелл стоит на приглашении (`pause_plan::shell_holding_terminal`):
//! иначе введённое досталось бы чужой программе.
//!
//! Запуски идут с потолком времени: зависший сервер tmux не должен держать поток.

use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::mpsc::{channel, RecvTimeoutError};
use std::time::Duration;

use weto_core::process::ProcessSnapshot;
use weto_core::terminal::program_name;

use crate::terminal_mode;

/// Потолок одного запуска tmux.
const COMMAND_CEILING: Duration = Duration::from_secs(2);

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum TerminalReturnError {
    /// Цель не под tmux, или запускать его нельзя: ввести `fg` за пользователя нечем.
    #[error("ввести fg нечем")]
    NoWayToType,
    /// tmux есть, а панели с терминалом цели на его сокетах нет.
    #[error("панель с терминалом цели не найдена")]
    PaneNotFound,
    /// Команда запустилась и не сработала: код выхода, -1 — кода нет.
    #[error("tmux завершился с кодом {0}")]
    CommandFailed(i32),
    #[error("tmux не ответил вовремя")]
    TimedOut,
}

pub trait TerminalForegroundReturning: Send + Sync {
    fn return_to_foreground(
        &self,
        target: &ProcessSnapshot,
        shell: &ProcessSnapshot,
        processes: &[ProcessSnapshot],
    ) -> Result<(), TerminalReturnError>;
}

pub struct TmuxForegroundReturner;

impl TerminalForegroundReturning for TmuxForegroundReturner {
    fn return_to_foreground(
        &self,
        target: &ProcessSnapshot,
        shell: &ProcessSnapshot,
        processes: &[ProcessSnapshot],
    ) -> Result<(), TerminalReturnError> {
        // SAFETY: geteuid не имеет побочных эффектов и не падает.
        let euid = unsafe { libc::geteuid() };
        if !may_type(euid) {
            return Err(TerminalReturnError::NoWayToType);
        }
        let tty = terminal_mode::path_of(target.terminal_device)
            .ok_or(TerminalReturnError::NoWayToType)?;
        let tmux = processes
            .iter()
            .find(|process| process.pid == shell.parent_pid)
            .filter(|process| program_name(&process.executable_path) == "tmux")
            .filter(|process| {
                std::fs::metadata(&process.executable_path)
                    .is_ok_and(|meta| is_trusted_executable(meta.uid(), meta.mode(), euid))
            })
            .ok_or(TerminalReturnError::NoWayToType)?;

        type_through_tmux(&tmux.executable_path, &tty.to_string_lossy(), euid)
    }
}

/// Охрана от root стоит над всей машиной: процессы, которые она видит, принадлежат кому угодно,
/// и запускать что-либо по их подсказке значит отдать root локальному пользователю.
pub fn may_type(euid: u32) -> bool {
    euid != 0
}

/// Путь к tmux взят из таблицы процессов, а назвать свой процесс `tmux` может кто угодно.
/// Запускается только обычный файл, который никто другой изменить не может. `mode` — `st_mode`
/// целиком, вместе с типом файла.
pub fn is_trusted_executable(owner: u32, mode: u32, euid: u32) -> bool {
    mode & libc::S_IFMT == libc::S_IFREG
        && (owner == 0 || owner == euid)
        && mode & (libc::S_IWGRP | libc::S_IWOTH) == 0
}

/// `/tmp` общий: каталог `tmux-<uid>` мог заранее создать другой пользователь, и сокет в нём
/// слушал бы он. Требование то же, что у самого tmux: наш и закрыт для остальных. `mode` —
/// `st_mode` из `lstat`, поэтому симлинк на каталог каталогом не считается.
pub fn is_trusted_socket_directory(owner: u32, mode: u32, euid: u32) -> bool {
    mode & libc::S_IFMT == libc::S_IFDIR
        && owner == euid
        && mode & (libc::S_IRWXG | libc::S_IRWXO) == 0
}

/// Строка `list-panes`: `#{pane_tty} #{pane_id}`. Панель ищется по терминалу цели, а не по
/// догадке: панелей на сервере много.
pub fn pane_id<'a>(tty: &str, listing: &'a str) -> Option<&'a str> {
    listing.lines().find_map(|line| {
        let (pane_tty, pane) = line.split_once(' ')?;
        (pane_tty == tty && !pane.contains(' ')).then_some(pane)
    })
}

/// Сокеты сервера tmux: панели ищутся перебором, потому что на машине их бывает несколько
/// (`tmux -L`). Каталог, которому нельзя верить, панелей не содержит.
fn tmux_sockets(directory: &Path, euid: u32) -> Vec<String> {
    let trusted = std::fs::symlink_metadata(directory)
        .is_ok_and(|meta| is_trusted_socket_directory(meta.uid(), meta.mode(), euid));
    if !trusted {
        return Vec::new();
    }
    let mut sockets: Vec<String> = std::fs::read_dir(directory)
        .into_iter()
        .flatten()
        .flatten()
        .map(|entry| entry.path().to_string_lossy().into_owned())
        .collect();
    sockets.sort();
    sockets
}

/// Мёртвые сокеты после упавших серверов отвечают ошибкой и пропускаются.
fn type_through_tmux(binary: &str, tty: &str, euid: u32) -> Result<(), TerminalReturnError> {
    let directory = format!("/tmp/tmux-{euid}");
    for socket in tmux_sockets(Path::new(&directory), euid) {
        let Ok(listing) = run(
            binary,
            &[
                "-S",
                &socket,
                "list-panes",
                "-a",
                "-F",
                "#{pane_tty} #{pane_id}",
            ],
            COMMAND_CEILING,
        ) else {
            continue;
        };
        let Some(pane) = pane_id(tty, &listing) else {
            continue;
        };

        // C-u отдельной командой: набранное в строке шелла иначе склеилось бы с `fg`.
        let _ = run(
            binary,
            &["-S", &socket, "send-keys", "-t", pane, "C-u"],
            COMMAND_CEILING,
        );
        return run(
            binary,
            &["-S", &socket, "send-keys", "-t", pane, "fg", "Enter"],
            COMMAND_CEILING,
        )
        .map(|_| ());
    }
    Err(TerminalReturnError::PaneNotFound)
}

/// Запуск с потолком времени. Ждёт отдельный поток: чтение вывода и ожидание выхода нельзя
/// поделить на один — заполненная труба держала бы процесс до потолка. После убийства поток
/// дожидается процесса сам, зомби не остаётся.
fn run(path: &str, arguments: &[&str], ceiling: Duration) -> Result<String, TerminalReturnError> {
    let child = Command::new(path)
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| TerminalReturnError::CommandFailed(-1))?;
    let pid = child.id() as i32;

    let (sender, receiver) = channel();
    std::thread::spawn(move || {
        let _ = sender.send(child.wait_with_output());
    });

    match receiver.recv_timeout(ceiling) {
        Ok(Ok(output)) if output.status.success() => {
            Ok(String::from_utf8_lossy(&output.stdout).into_owned())
        }
        Ok(Ok(output)) => Err(TerminalReturnError::CommandFailed(
            output.status.code().unwrap_or(-1),
        )),
        Ok(Err(_)) | Err(RecvTimeoutError::Disconnected) => {
            Err(TerminalReturnError::CommandFailed(-1))
        }
        Err(RecvTimeoutError::Timeout) => {
            // SAFETY: pid нашего ещё не дождавшегося ребёнка: номер занят, пока его не прочитали.
            unsafe { libc::kill(pid, libc::SIGKILL) };
            Err(TerminalReturnError::TimedOut)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    const ME: u32 = 1000;
    const FILE: u32 = libc::S_IFREG;
    const DIRECTORY: u32 = libc::S_IFDIR;

    /// Панель ищется по терминалу цели, а не по догадке: панелей на сервере много.
    #[test]
    fn the_pane_is_found_by_its_terminal() {
        let listing = "/dev/pts/1 %0\n/dev/pts/14 %3\n";
        assert_eq!(pane_id("/dev/pts/14", listing), Some("%3"));
        assert_eq!(
            pane_id("/dev/pts/4", listing),
            None,
            "только точное совпадение"
        );
    }

    /// Назвать процесс `tmux` может кто угодно: запускаем только то, что принадлежит root
    /// или нам и не открыто на запись другим.
    #[test]
    fn only_a_binary_nobody_else_can_change_is_run() {
        assert!(is_trusted_executable(0, FILE | 0o755, ME));
        assert!(is_trusted_executable(ME, FILE | 0o755, ME));
        assert!(
            !is_trusted_executable(1001, FILE | 0o755, ME),
            "чужой бинарник с именем tmux"
        );
        assert!(
            !is_trusted_executable(ME, FILE | 0o775, ME),
            "группа может подменить"
        );
        assert!(
            !is_trusted_executable(0, FILE | 0o757, ME),
            "кто угодно может подменить"
        );
        assert!(
            !is_trusted_executable(ME, DIRECTORY | 0o755, ME),
            "запускается только обычный файл"
        );
    }

    /// `/tmp` общий: каталог `tmux-<uid>` мог заранее создать другой пользователь.
    #[test]
    fn only_our_private_socket_directory_is_used() {
        assert!(is_trusted_socket_directory(ME, DIRECTORY | 0o700, ME));
        assert!(
            !is_trusted_socket_directory(1001, DIRECTORY | 0o700, ME),
            "чужой каталог"
        );
        assert!(
            !is_trusted_socket_directory(ME, DIRECTORY | 0o750, ME),
            "у группы есть права"
        );
        assert!(
            !is_trusted_socket_directory(ME, DIRECTORY | 0o701, ME),
            "у остальных есть права"
        );
        assert!(
            !is_trusted_socket_directory(ME, libc::S_IFLNK | 0o700, ME),
            "симлинк каталогом не считается"
        );
    }

    /// От root охрана стоит над всей машиной, и ввод в чужие сессии ей не нужен и опасен.
    #[test]
    fn root_types_into_nothing() {
        assert!(!may_type(0));
        assert!(may_type(ME));
    }

    /// Чужой или открытый каталог панелей не содержит, настоящий — отдаёт сокеты по порядку.
    /// Симлинк на правильный каталог не проходит: lstat видит сам симлинк.
    #[test]
    fn sockets_come_only_from_a_trusted_directory() {
        let home = tempfile::tempdir().expect("каталог");
        let euid = unsafe { libc::geteuid() };
        let directory = home.path().join("tmux");
        std::fs::create_dir(&directory).unwrap();
        std::fs::write(directory.join("b"), "").unwrap();
        std::fs::write(directory.join("a"), "").unwrap();

        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700)).unwrap();
        let found = tmux_sockets(&directory, euid);
        assert_eq!(found.len(), 2);
        assert!(found[0].ends_with("/a") && found[1].ends_with("/b"));

        assert!(
            tmux_sockets(&directory, euid + 1).is_empty(),
            "владелец не мы"
        );

        let link = home.path().join("link");
        std::os::unix::fs::symlink(&directory, &link).unwrap();
        assert!(tmux_sockets(&link, euid).is_empty(), "симлинк не считается");

        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o770)).unwrap();
        assert!(tmux_sockets(&directory, euid).is_empty(), "права у группы");
    }

    /// Цель не под tmux: отказ сразу, без запуска чего-либо.
    #[test]
    fn without_tmux_the_return_is_refused() {
        let shell = ProcessSnapshot {
            pid: 100,
            parent_pid: 90,
            executable_path: "/bin/zsh".to_string(),
            terminal_device: 34816,
            ..ProcessSnapshot::default()
        };
        let host = ProcessSnapshot {
            pid: 90,
            parent_pid: 1,
            executable_path: "/usr/bin/gnome-terminal-server".to_string(),
            ..ProcessSnapshot::default()
        };
        let target = ProcessSnapshot {
            pid: 200,
            parent_pid: 100,
            terminal_device: 0,
            executable_path: "/usr/bin/node".to_string(),
            ..ProcessSnapshot::default()
        };
        assert_eq!(
            TmuxForegroundReturner.return_to_foreground(&target, &shell, &[host, shell.clone()]),
            Err(TerminalReturnError::NoWayToType)
        );
    }

    #[test]
    fn a_command_answers_with_its_output_or_its_exit_code() {
        assert_eq!(
            run("/bin/echo", &["%3"], COMMAND_CEILING).as_deref(),
            Ok("%3\n")
        );
        assert_eq!(
            run("/bin/false", &[], COMMAND_CEILING),
            Err(TerminalReturnError::CommandFailed(1))
        );
        assert_eq!(
            run("/no/such/tmux", &[], COMMAND_CEILING),
            Err(TerminalReturnError::CommandFailed(-1))
        );
    }

    /// Зависший сервер tmux не держит поток дольше потолка.
    #[test]
    fn a_hung_command_is_killed_at_the_ceiling() {
        let started = std::time::Instant::now();
        assert_eq!(
            run("/bin/sleep", &["30"], Duration::from_millis(100)),
            Err(TerminalReturnError::TimedOut)
        );
        assert!(started.elapsed() < Duration::from_secs(5));
    }
}
