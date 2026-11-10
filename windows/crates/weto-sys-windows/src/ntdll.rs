//! Функции ntdll, которых нет в `windows-sys`.
//!
//! `NtSuspendProcess` и `NtResumeProcess` не документированы, но стабильны
//! с Windows XP: ими приостанавливают процесс Монитор ресурсов и Process
//! Explorer. Объявлены через `windows-link` — тем же способом линкуется сам
//! `windows-sys`, без import-библиотек.

use windows_sys::Win32::Foundation::{HANDLE, NTSTATUS};

windows_link::link!("ntdll.dll" "system" fn NtSuspendProcess(process: HANDLE) -> NTSTATUS);
windows_link::link!("ntdll.dll" "system" fn NtResumeProcess(process: HANDLE) -> NTSTATUS);
windows_link::link!("ntdll.dll" "system" fn RtlNtStatusToDosError(status: NTSTATUS) -> u32);
windows_link::link!("ntdll.dll" "system" fn RtlGetVersion(info: *mut OsVersionInfo) -> NTSTATUS);

/// `RTL_OSVERSIONINFOW`. `GetVersionEx` врёт приложениям без манифеста
/// совместимости (называет Windows 8), `RtlGetVersion` — нет.
#[repr(C)]
pub struct OsVersionInfo {
    pub size: u32,
    pub major: u32,
    pub minor: u32,
    pub build: u32,
    pub platform: u32,
    pub service_pack: [u16; 128],
}

/// `STATUS_INFO_LENGTH_MISMATCH`: буфер мал, повторить с бо́льшим.
pub const STATUS_INFO_LENGTH_MISMATCH: NTSTATUS = 0xC000_0004_u32 as NTSTATUS;

/// `NTSTATUS` в код Win32 — тот же язык ошибок, что у `GetLastError`.
/// `None` — успех.
pub fn win32_error(status: NTSTATUS) -> Option<i32> {
    // SAFETY: чистое преобразование числа, без побочных эффектов.
    (status < 0).then(|| unsafe { RtlNtStatusToDosError(status) } as i32)
}
