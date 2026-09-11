//! Реестр процессов проверяется с двух сторон.
//!
//! Разбор — на фальшивом корне `/proc`: тест собирает во временном каталоге
//! ровно те файлы, которые читает адаптер, и получает полный контроль над
//! краями — исчезнувшим процессом, процессом ядра, именем с пробелами
//! и скобками, процессом без управляющего терминала.
//!
//! Согласие разбора с ядром — на живых процессах, которые тест запускает сам:
//! подложенный `stat` доказывает только то, что мы читаем свой же файл так,
//! как его написали. Поэтому контейнер и обязателен — тесты идут на настоящем
//! ядре.

use std::fs;
use std::path::Path;

use weto_sys::process_registry::{ProcRegistry, ProcessRegistryReading};

fn make_process(root: &Path, pid: i32, ppid: i32, exe: &str, argv: &[&str], comm: &str) {
    make_process_with_stat(
        root,
        pid,
        exe,
        argv,
        // Формат stat: pid (comm) state ppid pgrp session tty_nr tpgid ...
        &format!("{pid} ({comm}) S {ppid} 0 0 0 -1 4194304"),
    );
}

fn make_process_with_stat(root: &Path, pid: i32, exe: &str, argv: &[&str], stat: &str) {
    let dir = root.join(pid.to_string());
    fs::create_dir_all(&dir).unwrap();

    std::os::unix::fs::symlink(exe, dir.join("exe")).unwrap();

    let mut cmdline = Vec::new();
    for argument in argv {
        cmdline.extend_from_slice(argument.as_bytes());
        cmdline.push(0);
    }
    fs::write(dir.join("cmdline"), cmdline).unwrap();
    fs::write(dir.join("stat"), stat).unwrap();
}

#[test]
fn registry_reads_path_arguments_and_parent() {
    let tmp = tempfile::tempdir().unwrap();
    make_process(
        tmp.path(),
        42,
        1,
        "/usr/bin/node",
        &["node", "/usr/local/bin/qwen", "--chat"],
        "node",
    );

    let processes = ProcRegistry::rooted(tmp.path().into()).snapshot();

    assert_eq!(processes.len(), 1);
    assert_eq!(processes[0].pid, 42);
    assert_eq!(processes[0].parent_pid, 1);
    assert_eq!(processes[0].executable_path, "/usr/bin/node");
    assert_eq!(
        processes[0].arguments.as_deref(),
        Some(
            ["node", "/usr/local/bin/qwen", "--chat"]
                .map(String::from)
                .as_slice()
        )
    );
}

#[test]
fn non_numeric_entries_are_ignored() {
    let tmp = tempfile::tempdir().unwrap();
    make_process(tmp.path(), 7, 1, "/usr/bin/nano", &["nano"], "nano");
    fs::create_dir_all(tmp.path().join("sys")).unwrap();
    fs::write(tmp.path().join("uptime"), "1 2").unwrap();

    assert_eq!(ProcRegistry::rooted(tmp.path().into()).snapshot().len(), 1);
}

/// Процесс исчезает между обходом каталога и чтением файлов постоянно.
/// Это норма, а не ошибка: снимок обязан просто пропустить его.
#[test]
fn a_process_that_vanished_mid_read_is_skipped_silently() {
    let tmp = tempfile::tempdir().unwrap();
    make_process(tmp.path(), 7, 1, "/usr/bin/nano", &["nano"], "nano");
    fs::remove_file(tmp.path().join("7/exe")).unwrap();

    assert!(ProcRegistry::rooted(tmp.path().into())
        .snapshot()
        .is_empty());
}

/// У процессов ядра `cmdline` пуст. Целью они быть не могут, и путать их
/// с процессом без аргументов нельзя.
#[test]
fn kernel_threads_have_no_arguments() {
    let tmp = tempfile::tempdir().unwrap();
    make_process(tmp.path(), 2, 0, "/proc/2/exe", &[], "kthreadd");

    let processes = ProcRegistry::rooted(tmp.path().into()).snapshot();
    assert_eq!(processes.len(), 1);
    assert_eq!(processes[0].arguments, None);
}

/// Имя процесса в `stat` заключено в скобки и может содержать что угодно —
/// пробелы, скобки, всё сразу. Разбор по номеру пробела здесь ломается,
/// и ppid уезжает в другое поле.
#[test]
fn parent_is_parsed_even_when_the_process_name_contains_spaces_and_brackets() {
    let tmp = tempfile::tempdir().unwrap();
    make_process(
        tmp.path(),
        99,
        1234,
        "/usr/bin/weird",
        &["weird"],
        "имя (со) скобками",
    );

    let processes = ProcRegistry::rooted(tmp.path().into()).snapshot();
    assert_eq!(processes[0].parent_pid, 1234);
}

#[test]
fn a_missing_proc_root_yields_an_empty_snapshot_instead_of_a_panic() {
    let registry = ProcRegistry::rooted("/несуществующий/proc".into());
    assert!(registry.snapshot().is_empty());
}

/// Фальшивый корень проверяет разбор, но не то, что разбор совпадает с тем,
/// что кладёт в `/proc` настоящее ядро. Этот тест закрывает разрыв: реестр
/// обязан увидеть сам процесс теста со всеми полями.
#[test]
fn the_real_proc_contains_the_test_process_itself() {
    let me = std::process::id() as i32;
    let processes = ProcRegistry::new().snapshot();

    let mine = processes
        .iter()
        .find(|process| process.pid == me)
        .expect("реестр обязан видеть сам себя");

    assert!(
        mine.executable_path.contains("process_registry"),
        "путь исполняемого файла: {}",
        mine.executable_path
    );
    assert!(mine.arguments.is_some(), "у теста есть командная строка");
    assert!(mine.parent_pid > 0, "у теста есть родитель");
    assert!(
        processes.len() > 1,
        "в системе больше одного процесса, снимок не должен обрываться на первом"
    );
}

// --- поля плана паузы -------------------------------------------------------

/// Группа, передняя группа терминала и остановленность приезжают из тех же
/// `stat`, что и родитель. Проверяются на фальшивом корне, потому что живое
/// ядро не даст стоящему процессу нужное сочетание полей по заказу.
#[test]
fn group_terminal_and_stopped_state_come_from_stat() {
    let tmp = tempfile::tempdir().unwrap();
    make_process_with_stat(
        tmp.path(),
        31,
        "/usr/bin/nano",
        &["nano"],
        // pid (comm) state ppid pgrp session tty_nr tpgid ...
        "31 (nano) T 30 31 29 34816 777 4194304",
    );

    let processes = ProcRegistry::rooted(tmp.path().into()).snapshot();

    assert_eq!(processes[0].parent_pid, 30);
    assert_eq!(processes[0].process_group, 31);
    assert_eq!(processes[0].terminal_foreground_group, 777);
    assert!(processes[0].is_stopped);
}

/// Ядро пишет в tpgid -1 процессу без управляющего терминала, а план паузы
/// ждёт нуля: «терминала нет» у него — 0, и -1 объявило бы фоновым заданием
/// чужой группы то, у чего терминала нет вовсе. Приводит граница.
#[test]
fn a_process_without_a_controlling_terminal_reports_zero_not_minus_one() {
    let tmp = tempfile::tempdir().unwrap();
    make_process_with_stat(
        tmp.path(),
        41,
        "/usr/bin/weto",
        &["weto"],
        "41 (weto) S 1 41 41 0 -1 4194304",
    );

    let processes = ProcRegistry::rooted(tmp.path().into()).snapshot();

    assert_eq!(processes[0].terminal_foreground_group, 0);
}

/// `t` — остановка трассировщиком, а не сигналом. Пользовательского Ctrl-Z
/// в ней нет, и трогать такой процесс плану паузы незачем.
#[test]
fn a_tracing_stop_is_not_the_stop_the_plan_means() {
    let tmp = tempfile::tempdir().unwrap();
    make_process_with_stat(
        tmp.path(),
        42,
        "/usr/bin/nano",
        &["nano"],
        "42 (nano) t 1 42 42 34816 42 4194304",
    );

    assert!(!ProcRegistry::rooted(tmp.path().into()).snapshot()[0].is_stopped);
}

/// Ловушка `comm` касается не только ppid: имя с пробелами и скобками сдвигает
/// **все** поля сразу, и разбор по номеру пробела увёл бы в мусор ещё и группу
/// с передней группой терминала.
#[test]
fn every_field_survives_a_process_name_with_spaces_and_brackets() {
    let tmp = tempfile::tempdir().unwrap();
    make_process_with_stat(
        tmp.path(),
        99,
        "/usr/bin/weird",
        &["weird"],
        "99 (имя (со) скобками) T 1234 55 55 34816 66 4194304",
    );

    let processes = ProcRegistry::rooted(tmp.path().into()).snapshot();

    assert_eq!(processes[0].parent_pid, 1234);
    assert_eq!(processes[0].process_group, 55);
    assert_eq!(processes[0].terminal_foreground_group, 66);
    assert!(processes[0].is_stopped);
}

// --- живое ядро -------------------------------------------------------------

/// Убивает за собой в любом исходе: провалившийся ассерт не должен оставить
/// ни живого, ни замороженного процесса. SIGCONT раньше SIGKILL не нужен —
/// SIGKILL доходит и до стоящего, — но нужен всем, кого мы могли остановить
/// и не успеть возобновить.
struct Spawned(std::process::Child);

impl Drop for Spawned {
    fn drop(&mut self) {
        let pid = self.0.id() as i32;
        unsafe { libc::kill(pid, libc::SIGCONT) };
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

impl Spawned {
    fn pid(&self) -> i32 {
        self.0.id() as i32
    }
}

fn snapshot_of(pid: i32) -> Option<weto_core::process::ProcessSnapshot> {
    ProcRegistry::new()
        .snapshot()
        .into_iter()
        .find(|process| process.pid == pid)
}

/// Ждёт процесс, запущенный не нами напрямую (потомок `script`): между
/// `spawn` и появлением в `/proc` проходит время.
fn wait_for_process(marker: &str) -> weto_core::process::ProcessSnapshot {
    for _ in 0..100 {
        let found = ProcRegistry::new().snapshot().into_iter().find(|process| {
            process
                .arguments
                .as_ref()
                .is_some_and(|argv| argv.iter().any(|argument| argument == marker))
                && process.executable_path.ends_with("/sleep")
        });
        if let Some(process) = found {
            return process;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    panic!("процесс с меткой {marker} так и не появился в /proc");
}

/// Группа процессов сверяется с независимым источником — `getpgid(2)`,
/// а не с догадкой по родителю.
#[test]
fn the_real_proc_reports_the_process_group() {
    let child = Spawned(
        std::process::Command::new("sleep")
            .arg("86400")
            .spawn()
            .unwrap(),
    );

    let snapshot = snapshot_of(child.pid()).expect("реестр обязан видеть потомка");

    assert_eq!(snapshot.process_group, unsafe {
        libc::getpgid(child.pid())
    });
    assert!(snapshot.process_group > 0);
}

/// Управляющий терминал заводится честным pty через `script`: у процесса
/// в нём передняя группа терминала непустая и совпадает с его группой — это
/// и есть переднее задание, ради которого план паузы трогает шелл.
///
/// Терминал раннера для этого не годится: под CI его может не быть вовсе,
/// и проверка молча выродилась бы в «ноль равен нулю».
#[test]
fn a_process_with_a_controlling_terminal_reports_the_foreground_group() {
    let _script = Spawned(
        std::process::Command::new("script")
            .args(["-q", "-e", "-c", "sleep 86401", "/dev/null"])
            .stdout(std::process::Stdio::null())
            .spawn()
            .unwrap(),
    );

    let sleeping = wait_for_process("86401");
    // Потомок `script` переживает смерть самого `script` не всегда, но пусть
    // и не переживёт — обязательство закрываем сами.
    let _guard = scopeguard(sleeping.pid);

    assert!(
        sleeping.terminal_foreground_group > 0,
        "у процесса в pty есть передняя группа терминала"
    );
    assert_eq!(sleeping.terminal_foreground_group, sleeping.process_group);
}

/// А без управляющего терминала — ноль, и именно ноль: ядро пишет сюда -1,
/// и нормализация границы проверяется на настоящем `/proc`, а не только
/// на подложенном файле.
#[test]
fn a_process_without_a_controlling_terminal_reports_zero_on_the_real_proc() {
    use std::os::unix::process::CommandExt;

    let mut command = std::process::Command::new("sleep");
    command.arg("86402");
    // `setsid` в потомке отцепляет управляющий терминал: ровно тот случай,
    // ради которого нормализация и существует.
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let child = Spawned(command.spawn().unwrap());

    let snapshot = snapshot_of(child.pid()).expect("реестр обязан видеть потомка");

    assert_eq!(snapshot.terminal_foreground_group, 0);
    assert_eq!(
        snapshot.process_group,
        child.pid(),
        "потомок — лидер сессии"
    );
}

/// Остановленность проверяется настоящим SIGSTOP, а не подложенным `stat`:
/// сигнал шлётся мимо нашей же границы сигналов — иначе тест доказывал бы
/// согласие двух наших ошибок, а не то, что говорит ядро.
#[test]
fn the_real_proc_reports_a_stopped_process() {
    let child = Spawned(
        std::process::Command::new("sleep")
            .arg("86403")
            .spawn()
            .unwrap(),
    );

    assert_eq!(snapshot_of(child.pid()).map(|p| p.is_stopped), Some(false));

    assert_eq!(unsafe { libc::kill(child.pid(), libc::SIGSTOP) }, 0);
    assert!(
        wait_for_stopped(child.pid(), true),
        "остановленный процесс обязан быть виден остановленным"
    );

    assert_eq!(unsafe { libc::kill(child.pid(), libc::SIGCONT) }, 0);
    assert!(
        wait_for_stopped(child.pid(), false),
        "после SIGCONT остановленности больше нет"
    );
}

/// Ядру нужно мгновение, чтобы перевести процесс в `T` и обратно.
fn wait_for_stopped(pid: i32, expected: bool) -> bool {
    for _ in 0..100 {
        if snapshot_of(pid).map(|process| process.is_stopped) == Some(expected) {
            return true;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    false
}

/// Обязательство убить найденный не нами pid — тем же способом, что и у прямого
/// потомка: в любом исходе теста, включая провалившийся ассерт.
fn scopeguard(pid: i32) -> impl Drop {
    struct Kill(i32);
    impl Drop for Kill {
        fn drop(&mut self) {
            unsafe { libc::kill(self.0, libc::SIGCONT) };
            unsafe { libc::kill(self.0, libc::SIGKILL) };
        }
    }
    Kill(pid)
}
