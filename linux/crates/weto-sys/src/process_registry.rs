//! Реестр процессов через `/proc`.
//!
//! Замена макосной паре `libproc` + `KERN_PROCARGS2`, и заметно более дешёвая:
//! путь исполняемого файла ядро уже разрешило (`readlink /proc/<pid>/exe`),
//! а argv лежит готовым массивом в `cmdline`, разделённый нулями.
//!
//! Корень подменяем: тест собирает во временном каталоге дерево из нескольких
//! файлов и проверяет отбор без единого живого процесса.

use std::fs;
use std::path::{Path, PathBuf};

use weto_core::process::ProcessSnapshot;

pub trait ProcessRegistryReading: Send + Sync {
    fn snapshot(&self) -> Vec<ProcessSnapshot>;
}

pub struct ProcRegistry {
    root: PathBuf,
}

impl ProcRegistry {
    pub fn new() -> ProcRegistry {
        ProcRegistry {
            root: PathBuf::from("/proc"),
        }
    }

    pub fn rooted(root: PathBuf) -> ProcRegistry {
        ProcRegistry { root }
    }

    fn read_process(&self, pid: i32) -> Option<ProcessSnapshot> {
        let dir = self.root.join(pid.to_string());

        // Порядок важен: cmdline читается до exe, потому что у процессов ядра
        // cmdline пуст, и такие отсеиваются раньше, чем мы трогаем симлинк.
        let arguments = read_cmdline(&dir.join("cmdline"))?;
        let executable_path = fs::read_link(dir.join("exe"))
            .ok()?
            .to_string_lossy()
            .into_owned();
        let parent_pid = read_ppid(&dir.join("stat"))?;

        Some(ProcessSnapshot {
            pid,
            parent_pid,
            executable_path,
            arguments,
        })
    }
}

impl Default for ProcRegistry {
    fn default() -> Self {
        Self::new()
    }
}

impl ProcessRegistryReading for ProcRegistry {
    /// Любая ошибка чтения отдельного процесса — пропуск, а не отказ всего
    /// снимка: процессы исчезают под руками постоянно, и обход обязан это
    /// переживать молча.
    fn snapshot(&self) -> Vec<ProcessSnapshot> {
        let Ok(entries) = fs::read_dir(&self.root) else {
            return Vec::new();
        };

        entries
            .flatten()
            .filter_map(|entry| entry.file_name().to_str()?.parse::<i32>().ok())
            .filter_map(|pid| self.read_process(pid))
            .collect()
    }
}

/// `cmdline` — это argv, разделённый нулями, с нулём в конце. Пустой файл
/// означает процесс ядра: у него нет командной строки, и целью он быть не может.
fn read_cmdline(path: &Path) -> Option<Option<Vec<String>>> {
    let raw = fs::read(path).ok()?;
    if raw.is_empty() {
        return Some(None);
    }
    let arguments: Vec<String> = raw
        .split(|byte| *byte == 0)
        .filter(|chunk| !chunk.is_empty())
        .map(|chunk| String::from_utf8_lossy(chunk).into_owned())
        .collect();
    Some(if arguments.is_empty() {
        None
    } else {
        Some(arguments)
    })
}

/// Четвёртое поле `stat` — ppid. Второе поле (comm) заключено в скобки и может
/// содержать что угодно, включая пробелы и сами скобки, поэтому разбор идёт
/// от последней закрывающей скобки, а не по номеру пробела.
fn read_ppid(path: &Path) -> Option<i32> {
    let text = fs::read_to_string(path).ok()?;
    let after_comm = &text[text.rfind(')')? + 1..];
    after_comm.split_whitespace().nth(1)?.parse().ok()
}
