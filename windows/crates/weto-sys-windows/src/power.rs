//! Отказ от экономии энергии для охраны — аналог отказа от App Nap на macOS.
//!
//! Приложение в трее без окон — ровно тот процесс, который Windows 11 переводит
//! в EcoQoS (режим эффективности) и чьи запросы разрешения таймера
//! игнорирует. Опрос процессов раз в секунду (раз в 250 мс под паузой)
//! растянулся бы, и цель, запущенная под запретом, работала бы дольше.
//! Отказ — для всего процесса, на всё время жизни. Усыплять машину
//! пользователю это не мешает.

use windows_sys::Win32::Foundation::GetLastError;
use windows_sys::Win32::System::Threading::{
    GetCurrentProcess, ProcessPowerThrottling, SetProcessInformation,
    PROCESS_POWER_THROTTLING_CURRENT_VERSION, PROCESS_POWER_THROTTLING_EXECUTION_SPEED,
    PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION, PROCESS_POWER_THROTTLING_STATE,
};

/// Выключить троттлинг скорости и игнорирование разрешения таймера.
/// `Err` — код Win32: система старше Windows 10 1709 этого не знает.
pub fn keep_full_speed() -> Result<(), u32> {
    let state = PROCESS_POWER_THROTTLING_STATE {
        Version: PROCESS_POWER_THROTTLING_CURRENT_VERSION,
        // Маска управления называет, чем мы распоряжаемся; маска состояния
        // с нулями в этих битах — «не троттлить» (пример Microsoft «HighQoS»).
        ControlMask: PROCESS_POWER_THROTTLING_EXECUTION_SPEED
            | PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION,
        StateMask: 0,
    };
    // SAFETY: структура наша, размер — её размер; процесс — свой.
    let ok = unsafe {
        SetProcessInformation(
            GetCurrentProcess(),
            ProcessPowerThrottling,
            (&state as *const PROCESS_POWER_THROTTLING_STATE).cast(),
            std::mem::size_of::<PROCESS_POWER_THROTTLING_STATE>() as u32,
        )
    };
    if ok == 0 {
        // SAFETY: читается сразу после неудачного вызова.
        return Err(unsafe { GetLastError() });
    }
    Ok(())
}
