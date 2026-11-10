//! Время и версия системы для интерфейса и выгрузки журнала.

use std::time::{SystemTime, UNIX_EPOCH};

use windows_sys::Win32::Foundation::{FILETIME, SYSTEMTIME};
use windows_sys::Win32::System::Time::{FileTimeToSystemTime, SystemTimeToTzSpecificLocalTime};

use crate::ntdll::{OsVersionInfo, RtlGetVersion};

/// Секунды между 1601 и 1970 годами — началами отсчёта FILETIME и unix.
const EPOCH_GAP: u64 = 11_644_473_600;

/// «14:03:27» по часовому поясу пользователя — время проверки в показаниях.
pub fn local_hms(at: SystemTime) -> String {
    let seconds = at.duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs());
    let ticks = (seconds + EPOCH_GAP) * 10_000_000;
    let file_time = FILETIME {
        dwLowDateTime: ticks as u32,
        dwHighDateTime: (ticks >> 32) as u32,
    };
    // SAFETY: структуры наши; функции только пишут в них.
    unsafe {
        let mut utc: SYSTEMTIME = std::mem::zeroed();
        let mut local: SYSTEMTIME = std::mem::zeroed();
        if FileTimeToSystemTime(&file_time, &mut utc) == 0
            || SystemTimeToTzSpecificLocalTime(std::ptr::null(), &utc, &mut local) == 0
        {
            return "—".to_string();
        }
        format!(
            "{:02}:{:02}:{:02}",
            local.wHour, local.wMinute, local.wSecond
        )
    }
}

/// «Windows 10.0.26100» — для выгрузки журнала, как `/proc/version` на Linux.
pub fn os_version() -> String {
    // SAFETY: структура наша, размер выставлен, как требует функция.
    unsafe {
        let mut info: OsVersionInfo = std::mem::zeroed();
        info.size = std::mem::size_of::<OsVersionInfo>() as u32;
        if RtlGetVersion(&mut info) < 0 {
            return "Windows".to_string();
        }
        format!("Windows {}.{}.{}", info.major, info.minor, info.build)
    }
}
