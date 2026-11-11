//! Вернуть цель на передний план её терминала, введя `fg` в её шелл.
//!
//! Порт `macos/Sources/WetoSystem/TerminalForegroundReturner.swift`. Снаружи сессии терминал
//! не отдать: `tcsetpgrp` требует быть в этой сессии, а `TIOCSTI` не от root запрещён и с ядра
//! 6.2 закрыт вовсе. Остаётся ввод через того, кто терминал ведёт. AppleScript на Linux нет,
//! поэтому пути два — tmux и GNU screen: сервер каждого сразу продолжает остановленный шелл,
//! и тот забирает терминал у стоящей цели. В голом терминале шелл стоит вместе с целью, и она
//! остаётся впереди сама (проверено на bash и zsh). Под остальными — честный отказ, дальше
//! кнопка и окно терминала с подсказкой.
//!
//! Вызывать только когда шелл стоит на приглашении (`pause_plan::shell_holding_terminal`):
//! иначе введённое досталось бы чужой программе.
//!
//! Запуски идут с потолком времени: зависший сервер tmux не должен держать поток.

#[cfg(target_os = "linux")]
use std::os::unix::fs::MetadataExt;
#[cfg(target_os = "linux")]
use std::path::Path;
#[cfg(target_os = "linux")]
use std::process::{Command, Stdio};
#[cfg(target_os = "linux")]
use std::sync::mpsc::{channel, RecvTimeoutError};
#[cfg(target_os = "linux")]
use std::time::Duration;

use weto_core::process::ProcessSnapshot;
#[cfg(target_os = "linux")]
use weto_core::process::ProcessTree;
#[cfg(target_os = "linux")]
use weto_core::terminal::program_name;

#[cfg(target_os = "linux")]
use crate::terminal_mode;

/// Потолок одного запуска tmux.
#[cfg(target_os = "linux")]
const COMMAND_CEILING: Duration = Duration::from_secs(2);

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum TerminalReturnError {
    /// Цель не под tmux и не под screen, или запускать их нельзя: ввести `fg` нечем.
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

/// Граница для системы без job control (Windows): цель там не уходит в фон
/// от паузы, и вводить `fg` некуда. Шелла в плане паузы там не бывает
/// (`terminal_foreground_group = 0`), так что вызова не будет; ответ на него
/// честный — ввести нечем.
#[derive(Debug, Default, Clone, Copy)]
pub struct NoForegroundReturn;

impl TerminalForegroundReturning for NoForegroundReturn {
    fn return_to_foreground(
        &self,
        _target: &ProcessSnapshot,
        _shell: &ProcessSnapshot,
        _processes: &[ProcessSnapshot],
    ) -> Result<(), TerminalReturnError> {
        Err(TerminalReturnError::NoWayToType)
    }
}

#[cfg(target_os = "linux")]
pub struct MultiplexerForegroundReturner;

#[cfg(target_os = "linux")]
impl TerminalForegroundReturning for MultiplexerForegroundReturner {
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
        let (host, multiplexer) =
            multiplexer_above(shell, processes).ok_or(TerminalReturnError::NoWayToType)?;
        let trusted = std::fs::metadata(&host.executable_path)
            .is_ok_and(|meta| is_trusted_executable(meta.uid(), meta.mode(), euid));
        if !trusted {
            return Err(TerminalReturnError::NoWayToType);
        }

        match multiplexer {
            Multiplexer::Tmux => {
                let tty = terminal_mode::path_of(target.terminal_device)
                    .ok_or(TerminalReturnError::NoWayToType)?;
                type_through_tmux(&host.executable_path, &tty.to_string_lossy(), euid)
            }
            Multiplexer::Screen => type_through_screen(&host.executable_path, shell.pid),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg(target_os = "linux")]
pub enum Multiplexer {
    Tmux,
    Screen,
}

/// Сервер над шеллом. Не обязательно родитель: шелл бывает вложенным, `tmux → zsh → bash → цель`.
#[cfg(target_os = "linux")]
pub fn multiplexer_above<'a>(
    shell: &ProcessSnapshot,
    processes: &'a [ProcessSnapshot],
) -> Option<(&'a ProcessSnapshot, Multiplexer)> {
    ProcessTree::new(processes)
        .ancestors(shell.pid)
        .into_iter()
        .filter_map(|pid| processes.iter().find(|process| process.pid == pid))
        .find_map(|process| match program_name(&process.executable_path) {
            "tmux" => Some((process, Multiplexer::Tmux)),
            name if is_screen(name) => Some((process, Multiplexer::Screen)),
            _ => None,
        })
}

/// Охрана от root стоит над всей машиной: процессы, которые она видит, принадлежат кому угодно,
/// и запускать что-либо по их подсказке значит отдать root локальному пользователю.
#[cfg(target_os = "linux")]
pub fn may_type(euid: u32) -> bool {
    euid != 0
}

/// Путь к tmux взят из таблицы процессов, а назвать свой процесс `tmux` может кто угодно.
/// Запускается только обычный файл, который никто другой изменить не может. `mode` — `st_mode`
/// целиком, вместе с типом файла.
#[cfg(target_os = "linux")]
pub fn is_trusted_executable(owner: u32, mode: u32, euid: u32) -> bool {
    mode & libc::S_IFMT == libc::S_IFREG
        && (owner == 0 || owner == euid)
        && mode & (libc::S_IWGRP | libc::S_IWOTH) == 0
}

/// `/tmp` общий: каталог `tmux-<uid>` мог заранее создать другой пользователь, и сокет в нём
/// слушал бы он. Требование то же, что у самого tmux: наш и закрыт для остальных. `mode` —
/// `st_mode` из `lstat`, поэтому симлинк на каталог каталогом не считается.
#[cfg(target_os = "linux")]
pub fn is_trusted_socket_directory(owner: u32, mode: u32, euid: u32) -> bool {
    mode & libc::S_IFMT == libc::S_IFDIR
        && owner == euid
        && mode & (libc::S_IRWXG | libc::S_IRWXO) == 0
}

/// Двоичный файл screen на части дистрибутивов лежит с версией в имени.
#[cfg(target_os = "linux")]
pub fn is_screen(program: &str) -> bool {
    program == "screen"
        || program
            .strip_prefix("screen-")
            .is_some_and(|version| version.starts_with(|c: char| c.is_ascii_digit()))
}

/// Сессия и окно screen из окружения шелла (`/proc/<pid>/environ`). Выставил их сам сервер при
/// запуске шелла. Номер окна устаревает только после ручного `:number`; сверить его с терминалом
/// screen не даёт, такую цену оставляем.
#[cfg(target_os = "linux")]
pub fn screen_window(environ: &[u8]) -> Option<(&str, &str)> {
    let variable = |name: &[u8]| {
        environ
            .split(|byte| *byte == 0)
            .find_map(|entry| entry.strip_prefix(name))
            .and_then(|value| std::str::from_utf8(value).ok())
    };
    Some((variable(b"STY=")?, variable(b"WINDOW=")?))
}

/// Control-U впереди: набранное в строке шелла иначе склеилось бы с `fg`. Каталог сокетов
/// проверяет сам screen и с чужим или открытым работать отказывается.
#[cfg(target_os = "linux")]
fn type_through_screen(binary: &str, shell: i32) -> Result<(), TerminalReturnError> {
    let environ = std::fs::read(format!("/proc/{shell}/environ"))
        .map_err(|_| TerminalReturnError::NoWayToType)?;
    let (session, window) = screen_window(&environ).ok_or(TerminalReturnError::NoWayToType)?;
    run(
        binary,
        &["-S", session, "-p", window, "-X", "stuff", "\u{15}fg\n"],
        COMMAND_CEILING,
    )
    .map(|_| ())
}

/// Строка `list-panes`: `#{pane_tty} #{pane_id} #{pane_synchronized}`. Панель ищется по терминалу
/// цели, а не по догадке: панелей на сервере много. Панель с общим вводом (`synchronize-panes`)
/// не подходит: `fg` ушёл бы во все панели окна.
#[cfg(target_os = "linux")]
pub fn pane_id<'a>(tty: &str, listing: &'a str) -> Option<&'a str> {
    let fields = listing.lines().find_map(|line| {
        let mut fields = line.split(' ');
        (fields.next() == Some(tty)).then(|| (fields.next(), fields.next(), fields.next()))
    })?;
    match fields {
        (Some(pane), Some(synchronized), None) if synchronized != "1" => Some(pane),
        _ => None,
    }
}

/// Сокеты сервера tmux: панели ищутся перебором, потому что на машине их бывает несколько
/// (`tmux -L`). Каталог, которому нельзя верить, панелей не содержит.
#[cfg(target_os = "linux")]
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
#[cfg(target_os = "linux")]
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
                "#{pane_tty} #{pane_id} #{pane_synchronized}",
            ],
            COMMAND_CEILING,
        ) else {
            continue;
        };
        let Some(pane) = pane_id(tty, &listing) else {
            continue;
        };

        // Строка шелла редко пуста: цель включила отслеживание мыши и выключить его не может,
        // и отчёты идут в шелл без конца. Control-U стирает их, и всё одной командой: в зазор
        // между двумя вклинились бы новые, а Enter выполнил бы строку как команды.
        //
        // Сырыми байтами (`-H`), не именами клавиш: цель включила и расширенные клавиши, и при
        // `extended-keys on` `C-u` пришёл бы шеллу как `ESC[27;5;117~` и строку бы не стёр.
        return run(
            binary,
            &[
                "-S",
                &socket,
                "send-keys",
                "-t",
                pane,
                "-H",
                "15",
                "66",
                "67",
                "0d",
            ],
            COMMAND_CEILING,
        )
        .map(|_| ());
    }
    Err(TerminalReturnError::PaneNotFound)
}

/// Запуск с потолком времени. Ждёт отдельный поток: чтение вывода и ожидание выхода нельзя
/// поделить на один — заполненная труба держала бы процесс до потолка. После убийства поток
/// дожидается процесса сам, зомби не остаётся.
#[cfg(target_os = "linux")]
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
            // SAFETY: сигнал ничего не портит в памяти. Pid наш, но поток мог дождаться ребёнка
            // ровно на границе потолка: тогда номер уже свободен, а занять его за этот миг
            // другому процессу почти неоткуда.
            unsafe { libc::kill(pid, libc::SIGKILL) };
            Err(TerminalReturnError::TimedOut)
        }
    }
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    const ME: u32 = 1000;
    const FILE: u32 = libc::S_IFREG;
    const DIRECTORY: u32 = libc::S_IFDIR;

    /// Панель ищется по терминалу цели, а не по догадке: панелей на сервере много.
    #[test]
    fn the_pane_is_found_by_its_terminal() {
        let listing = "/dev/pts/1 %0 0\n/dev/pts/14 %3 0\n";
        assert_eq!(pane_id("/dev/pts/14", listing), Some("%3"));
        assert_eq!(
            pane_id("/dev/pts/4", listing),
            None,
            "только точное совпадение"
        );
    }

    /// С общим вводом панелей `fg` ушёл бы во все панели окна, а там чужие программы.
    #[test]
    fn a_pane_with_synchronized_input_is_not_typed_into() {
        let listing = "/dev/pts/1 %0 0\n/dev/pts/14 %3 1\n";
        assert_eq!(pane_id("/dev/pts/1", listing), Some("%0"));
        assert_eq!(pane_id("/dev/pts/14", listing), None);
    }

    /// Сервер бывает и не родителем шелла (`tmux → zsh → bash → цель`), а без него вводить нечем.
    #[test]
    fn the_multiplexer_is_found_above_a_nested_shell_and_only_there() {
        let process = |pid, parent_pid, path: &str| ProcessSnapshot {
            pid,
            parent_pid,
            executable_path: path.to_string(),
            ..ProcessSnapshot::default()
        };
        let processes = [
            process(90, 1, "/usr/bin/screen-4.9.1"),
            process(100, 90, "/bin/zsh"),
            process(150, 100, "/bin/bash"),
            process(290, 1, "/usr/bin/tmux"),
            process(300, 290, "/bin/zsh"),
            process(390, 1, "/usr/bin/gnome-terminal-server"),
            process(400, 390, "/bin/zsh"),
        ];
        let found = |shell: usize| {
            multiplexer_above(&processes[shell], &processes).map(|(host, kind)| (host.pid, kind))
        };
        assert_eq!(found(2), Some((90, Multiplexer::Screen)));
        assert_eq!(found(4), Some((290, Multiplexer::Tmux)));
        assert_eq!(found(6), None);
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

    /// Двоичный файл screen на части дистрибутивов лежит с версией в имени.
    #[test]
    fn screen_is_recognised_with_or_without_a_version() {
        assert!(is_screen("screen"));
        assert!(is_screen("screen-4.9.1"));
        assert!(!is_screen("screenfetch"));
        assert!(!is_screen("screen-saver"));
        assert!(!is_screen("tmux"));
    }

    /// Окно screen называет окружение шелла: `STY` и `WINDOW` выставляет сам сервер.
    #[test]
    fn the_screen_window_comes_from_the_shell_environment() {
        let environ = b"HOME=/h\0STY=123.pts-0.host\0TERM=screen\0WINDOW=2\0";
        assert_eq!(screen_window(environ), Some(("123.pts-0.host", "2")));
        assert_eq!(screen_window(b"HOME=/h\0STY=1.a\0"), None, "нет окна");
        assert_eq!(screen_window(b"WINDOW=2\0"), None, "нет сессии");
        assert_eq!(screen_window(b"STY=\xff\0WINDOW=2\0"), None, "не текст");
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
