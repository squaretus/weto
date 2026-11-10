//! Реестр процессов Windows.
//!
//! Один вызов `NtQuerySystemInformation(SystemProcessInformation)` даёт все
//! процессы разом — pid, родителя, время создания и потоки с их состоянием.
//! Путь и командная строка требуют открыть процесс, поэтому читаются один раз
//! на жизнь процесса и кэшируются по паре (pid, время создания): pid
//! переиспользуется, а время создания у нового процесса другое.
//!
//! Процесс, который открыть нельзя (системный, защищённый, запущенный
//! с повышением при обычном weto), в снимок не попадает — как процессы ядра
//! на Linux: целью он стать не может, сигнал ему всё равно не дойдёт.
//! Неудача не кэшируется: процесс мог ещё не дописать себя на миг первого чтения.

use std::collections::HashMap;
use std::sync::Mutex;

use windows_sys::Wdk::System::SystemInformation::{
    NtQuerySystemInformation, SystemProcessInformation,
};
use windows_sys::Wdk::System::Threading::{
    NtQueryInformationProcess, ProcessCommandLineInformation,
};
use windows_sys::Win32::Foundation::{CloseHandle, LocalFree, HANDLE};
use windows_sys::Win32::System::Threading::{
    OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows_sys::Win32::UI::Shell::CommandLineToArgvW;

use weto_core::process::ProcessSnapshot;
use weto_sys::process_registry::ProcessRegistryReading;

use crate::ntdll::STATUS_INFO_LENGTH_MISMATCH;
use crate::process_table::{self, RawProcess};
use crate::wide;

/// Начальный размер буфера: 820 процессов с потоками занимают около 400 КБ.
const INITIAL_BUFFER: usize = 512 * 1024;

#[derive(Debug, Clone)]
struct Identity {
    executable_path: String,
    arguments: Option<Vec<String>>,
}

#[derive(Default)]
pub struct NtProcessRegistry {
    identities: Mutex<HashMap<(i32, i64), Identity>>,
}

impl NtProcessRegistry {
    pub fn new() -> NtProcessRegistry {
        NtProcessRegistry::default()
    }
}

impl ProcessRegistryReading for NtProcessRegistry {
    fn snapshot(&self) -> Vec<ProcessSnapshot> {
        let raw = query_processes();
        let parents = process_table::trusted_parents(&raw);
        let mut identities = self.identities.lock().expect("кэш процессов");

        let snapshot: Vec<ProcessSnapshot> = raw
            .iter()
            .filter_map(|process| {
                let key = (process.pid, process.create_time);
                let identity = match identities.get(&key) {
                    Some(identity) => identity.clone(),
                    None => {
                        let identity = read_identity(process.pid)?;
                        identities.insert(key, identity.clone());
                        identity
                    }
                };
                Some(ProcessSnapshot {
                    pid: process.pid,
                    parent_pid: parents.get(&process.pid).copied().unwrap_or(0),
                    executable_path: identity.executable_path,
                    arguments: identity.arguments,
                    // Job control у Windows нет: ни групп, ни переднего задания
                    // терминала. Нули выключают шелл в плане паузы и снятие
                    // режима терминала.
                    process_group: 0,
                    terminal_foreground_group: 0,
                    terminal_device: 0,
                    is_stopped: process.is_suspended(),
                })
            })
            .collect();

        // Кэш живёт ровно столько, сколько процессы: завершившиеся уходят.
        let alive: std::collections::HashSet<(i32, i64)> =
            raw.iter().map(|p| (p.pid, p.create_time)).collect();
        identities.retain(|key, _| alive.contains(key));
        snapshot
    }
}

/// Все процессы. Буфер растёт, пока ядро отвечает «мал»: между вызовами
/// процессы рождаются, и запрошенного размера с запасом обычно хватает со второго раза.
fn query_processes() -> Vec<RawProcess> {
    let mut buffer = vec![0u8; INITIAL_BUFFER];
    for _ in 0..8 {
        let mut needed = 0u32;
        // SAFETY: буфер наш и живёт до конца вызова; ядро пишет не больше `len`.
        let status = unsafe {
            NtQuerySystemInformation(
                SystemProcessInformation,
                buffer.as_mut_ptr().cast(),
                buffer.len() as u32,
                &mut needed,
            )
        };
        if status == STATUS_INFO_LENGTH_MISMATCH {
            buffer.resize((needed as usize).max(buffer.len()) + 64 * 1024, 0);
            continue;
        }
        if status < 0 {
            return Vec::new();
        }
        return process_table::parse(&buffer);
    }
    Vec::new()
}

/// Путь и командная строка. `None` — открыть процесс не дали или пути нет.
fn read_identity(pid: i32) -> Option<Identity> {
    // SAFETY: открываем на чтение ограниченных сведений; handle закрывается ниже.
    let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid as u32) };
    if handle.is_null() {
        return None;
    }
    let path = image_path(handle);
    let arguments = command_line(handle);
    // SAFETY: handle открыт выше и закрывается ровно раз.
    unsafe { CloseHandle(handle) };
    Some(Identity {
        executable_path: path?,
        arguments,
    })
}

fn image_path(handle: HANDLE) -> Option<String> {
    let mut buffer = vec![0u16; 1024];
    loop {
        let mut length = buffer.len() as u32;
        // SAFETY: `length` — ёмкость буфера в символах; функция пишет не больше.
        let ok = unsafe {
            QueryFullProcessImageNameW(handle, PROCESS_NAME_WIN32, buffer.as_mut_ptr(), &mut length)
        };
        if ok != 0 {
            return Some(String::from_utf16_lossy(&buffer[..length as usize]));
        }
        // Длинные пути (до 32 767 символов) — единственная причина повторить.
        if buffer.len() >= 32 * 1024 {
            return None;
        }
        buffer.resize(buffer.len() * 4, 0);
    }
}

/// Командная строка через `ProcessCommandLineInformation` (Windows 8.1+):
/// ответ — `UNICODE_STRING` и сама строка сразу за ним в том же буфере.
fn command_line(handle: HANDLE) -> Option<Vec<String>> {
    let mut buffer = vec![0u8; 4096];
    loop {
        let mut needed = 0u32;
        // SAFETY: буфер наш, ядро пишет не больше `len`.
        let status = unsafe {
            NtQueryInformationProcess(
                handle,
                ProcessCommandLineInformation,
                buffer.as_mut_ptr().cast(),
                buffer.len() as u32,
                &mut needed,
            )
        };
        // Мал ли буфер, ядро говорит по-разному (`INFO_LENGTH_MISMATCH`,
        // `BUFFER_TOO_SMALL`, `BUFFER_OVERFLOW`), но нужный размер называет всегда.
        if status < 0 && (needed as usize) > buffer.len() && buffer.len() < 1 << 20 {
            buffer.resize(needed as usize, 0);
            continue;
        }
        if status < 0 {
            return None;
        }
        break;
    }
    // Заголовок — `UNICODE_STRING`: длина в байтах, ёмкость, указатель на строку
    // внутри этого же буфера.
    let header: process_table::UnicodeString =
        // SAFETY: ядро записало в начало буфера `UNICODE_STRING`.
        unsafe { std::ptr::read_unaligned(buffer.as_ptr().cast()) };
    if header.length == 0 || header.buffer == 0 {
        return None;
    }
    let units = header.length as usize / 2;
    // SAFETY: указатель ведёт в наш буфер, длина — от ядра.
    let text = unsafe { std::slice::from_raw_parts(header.buffer as *const u16, units) };
    split_command_line(text)
}

/// argv по правилам `CommandLineToArgvW` — тем же, по которым его разбирает
/// CRT запущенной программы. Пустая строка — `None`: для неё функция вернула бы
/// путь самого weto.
fn split_command_line(units: &[u16]) -> Option<Vec<String>> {
    if units
        .iter()
        .all(|&unit| unit == b' ' as u16 || unit == b'\t' as u16)
    {
        return None;
    }
    let text: Vec<u16> = units.iter().copied().chain(std::iter::once(0)).collect();
    let mut count = 0i32;
    // SAFETY: строка с нулём на конце; результат освобождается одним `LocalFree`.
    let list = unsafe { CommandLineToArgvW(text.as_ptr(), &mut count) };
    if list.is_null() {
        return None;
    }
    let arguments = (0..count as usize)
        // SAFETY: функция вернула `count` указателей на строки с нулём на конце.
        .map(|index| unsafe { wide::from_pointer(*list.add(index)) })
        .collect();
    // SAFETY: освобождается ровно раз, как велит документация.
    unsafe { LocalFree(list.cast()) };
    Some(arguments)
}
