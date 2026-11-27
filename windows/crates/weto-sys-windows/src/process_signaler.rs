//! Пауза, продолжение и завершение процессов Windows.
//!
//! Сигналов в Windows нет; соответствие такое:
//! - стоп — `NtSuspendProcess`: все потоки процесса приостанавливаются;
//! - продолжение — `NtResumeProcess`, один вызов на сигнал;
//! - завершение — `TerminateProcess`: без права на обработчик, как SIGKILL.
//!
//! **Стоп обязан быть идемпотентным, как SIGSTOP**, а приостановка Windows
//! считается: каждый `NtSuspendProcess` прибавляет единицу к счётчику каждого
//! потока, `NtResumeProcess` снимает одну. Охрана переспрашивает стоп раз
//! в 250 мс у цели из учёта, которая выглядит идущей, и на Windows так выглядит
//! и наша же стоящая: процесс стоит, когда стоят все его потоки, а поток,
//! родившийся в приостановленном процессе, приостановку не наследует. Рождает
//! их сама система — пул потоков поднимает исполнителя под завершения I/O,
//! и именно это происходит, когда VPN выключается и рвёт соединения цели.
//! Прежде каждый такой проход замораживал процесс ещё раз, одно «продолжить»
//! снимало один слой из многих, а живой новый поток убеждал учёт, что цель
//! пошла: запись уходила, и цель оставалась замороженной навсегда.
//!
//! Поэтому сигналер помнит процессы, которые приостановил сам (pid и время
//! создания: pid на Windows переиспользуется быстро). Повторный стоп такому
//! процессу — не второй `NtSuspendProcess`, а дозаморозка тех потоков, которые
//! ещё идут: у каждого потока ровно одна наша приостановка, и одного
//! `NtResumeProcess` хватает всем. Хватает его и после падения weto, когда
//! память сигналера пропала, а учёт остановленных продолжает записи со старта.
//!
//! Сигналы уходят строго в порядке списка — это часть контракта границы.
//! Код отказа — код Win32 (`GetLastError` или `NTSTATUS`, приведённый к нему).
//! «Процесса нет» — `PROCESS_GONE` (`ERROR_INVALID_PARAMETER`), и не только
//! когда так ответил `OpenProcess`: объект завершившегося процесса живёт, пока
//! на него держат handle, и тогда Windows отвечает «доступ запрещён» (5) —
//! так вёл себя `ping` сразу после выхода на раннерах windows-2025 и
//! windows-11-arm. Поэтому при любом отказе спрашивается, жив ли процесс.

use std::collections::HashMap;
use std::sync::Mutex;

use windows_sys::Win32::Foundation::{
    CloseHandle, GetLastError, ERROR_INVALID_HANDLE, ERROR_INVALID_PARAMETER, FILETIME, HANDLE,
    INVALID_HANDLE_VALUE, STILL_ACTIVE,
};
use windows_sys::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, Thread32First, Thread32Next, TH32CS_SNAPTHREAD, THREADENTRY32,
};
use windows_sys::Win32::System::Threading::{
    GetExitCodeProcess, GetProcessIdOfThread, GetProcessTimes, OpenProcess, OpenThread,
    ResumeThread, SuspendThread, TerminateProcess, PROCESS_QUERY_LIMITED_INFORMATION,
    PROCESS_SUSPEND_RESUME, PROCESS_TERMINATE, THREAD_QUERY_LIMITED_INFORMATION,
    THREAD_SUSPEND_RESUME,
};

use weto_sys::process_signaler::{ProcessSignal, ProcessSignaling, SignalResult, PROCESS_GONE};

use crate::ntdll::{win32_error, NtResumeProcess, NtSuspendProcess};

#[derive(Debug, Default)]
pub struct WindowsProcessSignaler {
    /// Процессы, приостановленные нами и ещё не продолженные: pid → время
    /// создания (`CreateTime`).
    held: Mutex<HashMap<i32, i64>>,
}

impl ProcessSignaling for WindowsProcessSignaler {
    fn send(&self, signal: ProcessSignal, pids: &[i32]) -> Vec<SignalResult> {
        pids.iter()
            .map(|pid| {
                let error_code = self.send_one(*pid, signal).map(|error| {
                    if *pid > 0 && has_exited(*pid) {
                        PROCESS_GONE
                    } else {
                        error
                    }
                });
                // Продолжен, завершён или исчез — наша приостановка снята.
                let gone = error_code == Some(PROCESS_GONE);
                if gone || (error_code.is_none() && signal != ProcessSignal::Stop) {
                    self.held().remove(pid);
                }
                SignalResult {
                    pid: *pid,
                    error_code,
                }
            })
            .collect()
    }
}

impl WindowsProcessSignaler {
    fn held(&self) -> std::sync::MutexGuard<'_, HashMap<i32, i64>> {
        self.held
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn send_one(&self, pid: i32, signal: ProcessSignal) -> Option<i32> {
        // pid 0 — учёт простоя, не процесс. `OpenProcess(0)` ответил бы «нет
        // такого», и отказ вызова выглядел бы как доставка; граница отказывает сама.
        if pid <= 0 {
            return Some(ERROR_INVALID_HANDLE as i32);
        }
        // Время создания нужно только стопу: продолжение просит ровно то право,
        // которым пользуется, и не получает отказа там, где его дали одно.
        let access = match signal {
            ProcessSignal::Kill => PROCESS_TERMINATE,
            ProcessSignal::Stop => PROCESS_SUSPEND_RESUME | PROCESS_QUERY_LIMITED_INFORMATION,
            ProcessSignal::Resume => PROCESS_SUSPEND_RESUME,
        };
        // SAFETY: handle закрывается ниже ровно раз.
        let handle = unsafe { OpenProcess(access, 0, pid as u32) };
        if handle.is_null() {
            // SAFETY: читается сразу после неудачного вызова.
            return Some(unsafe { GetLastError() } as i32);
        }
        let result = match signal {
            // SAFETY: handle открыт с правом завершения.
            ProcessSignal::Kill => unsafe {
                if TerminateProcess(handle, 1) == 0 {
                    Some(GetLastError() as i32)
                } else {
                    None
                }
            },
            ProcessSignal::Stop => self.stop(pid, handle),
            // SAFETY: handle открыт с правом приостановки.
            ProcessSignal::Resume => win32_error(unsafe { NtResumeProcess(handle) }),
        };
        // SAFETY: handle открыт выше.
        unsafe { CloseHandle(handle) };
        result
    }

    /// Первый стоп — `NtSuspendProcess`; повторный тому же процессу —
    /// дозаморозка ещё идущих потоков, без второго слоя у уже стоящих.
    fn stop(&self, pid: i32, handle: HANDLE) -> Option<i32> {
        let created = creation_time(handle);
        let mut held = self.held();
        // Время создания не прочиталось у процесса, который мы держим: второй
        // слой хуже пропущенного стопа чужому процессу с тем же pid.
        let ours = match created {
            Some(created) => held.get(&pid) == Some(&created),
            None => held.contains_key(&pid),
        };
        if ours {
            return suspend_running_threads(pid as u32);
        }
        // SAFETY: handle открыт с правом приостановки.
        let result = win32_error(unsafe { NtSuspendProcess(handle) });
        match (result, created) {
            (None, Some(created)) => {
                held.insert(pid, created);
            }
            // Время создания не прочиталось: процесс не запоминается — ключа,
            // который отличил бы его от чужого с тем же pid, нет.
            _ => {
                held.remove(&pid);
            }
        }
        result
    }
}

/// Время создания процесса — вместе с pid ключ процесса.
fn creation_time(handle: HANDLE) -> Option<i64> {
    let empty = FILETIME {
        dwLowDateTime: 0,
        dwHighDateTime: 0,
    };
    let (mut created, mut exited, mut kernel, mut user) = (empty, empty, empty, empty);
    // SAFETY: handle открыт с правом чтения ограниченных сведений, указатели живы.
    let read =
        unsafe { GetProcessTimes(handle, &mut created, &mut exited, &mut kernel, &mut user) };
    (read != 0).then_some(((created.dwHighDateTime as i64) << 32) | created.dwLowDateTime as i64)
}

/// Приостановить потоки процесса, у которых приостановки нет: стоящий поток
/// второй не получает. Поток, родившийся и успевший выйти между снимком
/// и вызовом, просто пропускается — следующий проход охраны увидит процесс
/// заново. Поток, который приостановил кто-то другой (`CREATE_SUSPENDED`
/// создателя), нашей приостановки не получает, и `NtResumeProcess` запустит его
/// раньше создателя — это свойство самого `NtResumeProcess`, было и прежде.
fn suspend_running_threads(pid: u32) -> Option<i32> {
    // SAFETY: снимок закрывается ниже ровно раз.
    let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0) };
    if snapshot == INVALID_HANDLE_VALUE {
        // SAFETY: читается сразу после неудачного вызова.
        return Some(unsafe { GetLastError() } as i32);
    }
    // SAFETY: обнулённая структура с верным dwSize — то, чего ждёт Thread32First.
    let mut entry: THREADENTRY32 = unsafe { std::mem::zeroed() };
    entry.dwSize = std::mem::size_of::<THREADENTRY32>() as u32;
    // SAFETY: снимок открыт, указатель на entry жив.
    let mut more = unsafe { Thread32First(snapshot, &mut entry) } != 0;
    while more {
        if entry.th32OwnerProcessID == pid {
            suspend_if_running(entry.th32ThreadID, pid);
        }
        // SAFETY: то же, что у Thread32First.
        more = unsafe { Thread32Next(snapshot, &mut entry) } != 0;
    }
    // SAFETY: снимок открыт выше.
    unsafe { CloseHandle(snapshot) };
    None
}

fn suspend_if_running(thread_id: u32, pid: u32) {
    // SAFETY: handle закрывается ниже ровно раз.
    let thread = unsafe {
        OpenThread(
            THREAD_SUSPEND_RESUME | THREAD_QUERY_LIMITED_INFORMATION,
            0,
            thread_id,
        )
    };
    if thread.is_null() {
        return;
    }
    // Номер потока тоже переиспользуется: поток обязан принадлежать процессу.
    // SAFETY: handle открыт с правом приостановки и чтения сведений.
    unsafe {
        if GetProcessIdOfThread(thread) == pid {
            let previous = SuspendThread(thread);
            // Поток уже стоял — его приостановка наша, второй слой снимается.
            if previous != 0 && previous != u32::MAX {
                ResumeThread(thread);
            }
        }
        CloseHandle(thread);
    }
}

/// Процесса больше нет: открыть его нельзя вовсе (`ERROR_INVALID_PARAMETER`)
/// или он открывается, но уже завершён. Процесс, который открыть не дали
/// по другой причине (защищённый, чужой), живым и считается: отказ настоящий.
fn has_exited(pid: i32) -> bool {
    // SAFETY: handle закрывается ниже ровно раз.
    let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid as u32) };
    if handle.is_null() {
        // SAFETY: читается сразу после неудачного вызова.
        return unsafe { GetLastError() } == ERROR_INVALID_PARAMETER;
    }
    let mut code = 0u32;
    // SAFETY: handle открыт с правом чтения ограниченных сведений.
    let read = unsafe { GetExitCodeProcess(handle, &mut code) };
    // SAFETY: handle открыт выше.
    unsafe { CloseHandle(handle) };
    read != 0 && code != STILL_ACTIVE as u32
}
