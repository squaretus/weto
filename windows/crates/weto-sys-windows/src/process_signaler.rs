//! Пауза, продолжение и завершение процессов Windows.
//!
//! Сигналов в Windows нет; соответствие такое:
//! - стоп — `NtSuspendProcess`: все потоки процесса приостанавливаются;
//! - продолжение — `NtResumeProcess`, один вызов на сигнал. Счётчик приостановки
//!   у потоков копится, но двойной заморозки план паузы не делает (уже стоящий
//!   процесс он не трогает), а если она случилась, учёт остановленных досылает
//!   «продолжить», пока не увидит процесс идущим;
//! - завершение — `TerminateProcess`: без права на обработчик, как SIGKILL.
//!
//! Сигналы уходят строго в порядке списка — это часть контракта границы.
//! Код отказа — код Win32 (`GetLastError` или `NTSTATUS`, приведённый к нему).
//! «Процесса нет» — `PROCESS_GONE` (`ERROR_INVALID_PARAMETER`), и не только
//! когда так ответил `OpenProcess`: объект завершившегося процесса живёт, пока
//! на него держат handle, и тогда Windows отвечает «доступ запрещён» (5) —
//! так вёл себя `ping` сразу после выхода на раннерах windows-2025 и
//! windows-11-arm. Поэтому при любом отказе спрашивается, жив ли процесс.

use windows_sys::Win32::Foundation::{
    CloseHandle, GetLastError, ERROR_INVALID_HANDLE, ERROR_INVALID_PARAMETER, STILL_ACTIVE,
};
use windows_sys::Win32::System::Threading::{
    GetExitCodeProcess, OpenProcess, TerminateProcess, PROCESS_QUERY_LIMITED_INFORMATION,
    PROCESS_SUSPEND_RESUME, PROCESS_TERMINATE,
};

use weto_sys::process_signaler::{ProcessSignal, ProcessSignaling, SignalResult, PROCESS_GONE};

use crate::ntdll::{win32_error, NtResumeProcess, NtSuspendProcess};

#[derive(Debug, Default, Clone, Copy)]
pub struct WindowsProcessSignaler;

impl ProcessSignaling for WindowsProcessSignaler {
    fn send(&self, signal: ProcessSignal, pids: &[i32]) -> Vec<SignalResult> {
        pids.iter()
            .map(|pid| SignalResult {
                pid: *pid,
                error_code: send_one(*pid, signal).map(|error| {
                    if *pid > 0 && has_exited(*pid) {
                        PROCESS_GONE
                    } else {
                        error
                    }
                }),
            })
            .collect()
    }
}

fn send_one(pid: i32, signal: ProcessSignal) -> Option<i32> {
    // pid 0 — учёт простоя, не процесс. `OpenProcess(0)` ответил бы «нет
    // такого», и отказ вызова выглядел бы как доставка; граница отказывает сама.
    if pid <= 0 {
        return Some(ERROR_INVALID_HANDLE as i32);
    }
    let access = match signal {
        ProcessSignal::Kill => PROCESS_TERMINATE,
        ProcessSignal::Stop | ProcessSignal::Resume => PROCESS_SUSPEND_RESUME,
    };
    // SAFETY: handle закрывается ниже ровно раз.
    let handle = unsafe { OpenProcess(access, 0, pid as u32) };
    if handle.is_null() {
        // SAFETY: читается сразу после неудачного вызова.
        return Some(unsafe { GetLastError() } as i32);
    }
    // SAFETY: handle открыт с нужным правом и жив до `CloseHandle`.
    let result = unsafe {
        match signal {
            ProcessSignal::Kill => {
                if TerminateProcess(handle, 1) == 0 {
                    Some(GetLastError() as i32)
                } else {
                    None
                }
            }
            ProcessSignal::Stop => win32_error(NtSuspendProcess(handle)),
            ProcessSignal::Resume => win32_error(NtResumeProcess(handle)),
        }
    };
    // SAFETY: handle открыт выше.
    unsafe { CloseHandle(handle) };
    result
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
