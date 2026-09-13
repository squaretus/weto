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
        let stat = read_stat(&dir.join("stat"))?;

        Some(ProcessSnapshot {
            pid,
            parent_pid: stat.parent_pid,
            executable_path,
            arguments,
            process_group: stat.process_group,
            terminal_foreground_group: stat.terminal_foreground_group,
            is_stopped: stat.is_stopped,
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

/// То из `/proc/<pid>/stat`, что нужно охране: родитель, группа процессов,
/// передняя группа управляющего терминала и признак остановки.
struct Stat {
    parent_pid: i32,
    process_group: i32,
    terminal_foreground_group: i32,
    is_stopped: bool,
}

/// Второе поле `stat` (comm) заключено в скобки и может содержать что угодно,
/// включая пробелы и сами скобки, поэтому отсчёт полей идёт от **последней**
/// закрывающей скобки, а не по номеру пробела: у процесса с именем
/// `имя (со) скобками` разбор по пробелам уводит ppid в чужое поле.
///
/// Нумерация дальше — от `state`: 0 state, 1 ppid, 2 pgrp, 3 session,
/// 4 tty_nr, 5 tpgid.
fn read_stat(path: &Path) -> Option<Stat> {
    let text = fs::read_to_string(path).ok()?;
    let after_comm = &text[text.rfind(')')? + 1..];
    let fields: Vec<&str> = after_comm.split_whitespace().collect();

    let terminal = field(&fields, 4);
    let foreground = field(&fields, 5);

    Some(Stat {
        parent_pid: fields.get(1)?.parse().ok()?,
        process_group: field(&fields, 2),
        // Процессу без управляющего терминала ядро пишет в tpgid -1, а план
        // паузы ждёт нуля («терминала нет»): приводит граница, а не ядро.
        terminal_foreground_group: if terminal == 0 || foreground < 0 {
            0
        } else {
            foreground
        },
        // `T` — остановлен сигналом: пользовательский Ctrl-Z или наша пауза.
        // `t` — остановка трассировщиком, это другое состояние и не она.
        is_stopped: fields.first() == Some(&"T"),
    })
}

/// Поля, которых может не оказаться, — не повод потерять процесс целиком:
/// снимок и без них знает путь, родителя и argv. 0 у группы значит «неизвестно».
fn field(fields: &[&str], index: usize) -> i32 {
    fields
        .get(index)
        .and_then(|value| value.parse().ok())
        .unwrap_or(0)
}
