//! Реестр процессов проверяется на фальшивом корне `/proc`.
//!
//! Живые процессы для этого не нужны: тест собирает во временном каталоге ровно
//! те файлы, которые читает адаптер, и получает полный контроль над краями —
//! исчезнувшим процессом, процессом ядра, именем с пробелами и скобками.

use std::fs;
use std::path::Path;

use weto_sys::process_registry::{ProcRegistry, ProcessRegistryReading};

fn make_process(root: &Path, pid: i32, ppid: i32, exe: &str, argv: &[&str], comm: &str) {
    let dir = root.join(pid.to_string());
    fs::create_dir_all(&dir).unwrap();

    std::os::unix::fs::symlink(exe, dir.join("exe")).unwrap();

    let mut cmdline = Vec::new();
    for argument in argv {
        cmdline.extend_from_slice(argument.as_bytes());
        cmdline.push(0);
    }
    fs::write(dir.join("cmdline"), cmdline).unwrap();

    // Формат stat: pid (comm) state ppid ...
    fs::write(
        dir.join("stat"),
        format!("{pid} ({comm}) S {ppid} 0 0 0 -1 4194304"),
    )
    .unwrap();
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
