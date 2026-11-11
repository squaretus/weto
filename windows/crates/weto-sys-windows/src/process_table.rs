//! Разбор ответа `NtQuerySystemInformation(SystemProcessInformation)`.
//!
//! Чистая часть реестра процессов: буфер в записи, записи в снимок. Вызова
//! API здесь нет, поэтому разбор тестируется синтетическим буфером на любой
//! 64-битной системе, в том числе в Linux-контейнере.
//!
//! Структуры свои, а не из `windows-sys`: там их урезанная winternl-версия,
//! где родитель назван `Reserved2`, а время создания спрятано в `Reserved1`.
//! Раскладка — по phnt (её же читают System Informer и Process Hacker);
//! сверяет её контракт на живой Windows: pid, родитель и время создания
//! своего процесса против `GetCurrentProcessId` и `GetProcessTimes`.

use std::collections::HashMap;

/// Состояние потока «ждёт» (`KTHREAD_STATE::Waiting`). В `windows-sys` этой
/// константы нет; значение подтверждают `Win32_Thread.ThreadState` в WMI
/// и `System.Diagnostics.ThreadState.Wait` в .NET.
pub const THREAD_STATE_WAITING: u32 = 5;

/// Причина ожидания «приостановлен» (`KWAIT_REASON::Suspended`).
pub const WAIT_REASON_SUSPENDED: u32 = 5;

/// `KWAIT_REASON::WrSuspended` — та же приостановка, которую ядро показывает
/// под другим номером у части потоков. Принимаются обе.
pub const WAIT_REASON_WR_SUSPENDED: u32 = 12;

/// Поток процесса: только то, по чему судят о приостановке.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RawThread {
    pub state: u32,
    pub wait_reason: u32,
}

/// Процесс как его называет ядро — до чтения пути и командной строки.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawProcess {
    pub pid: i32,
    pub parent_pid: i32,
    /// `CreateTime` — сотни наносекунд с 1601 года. Вместе с pid — ключ
    /// процесса: pid на Windows переиспользуется быстро.
    pub create_time: i64,
    pub threads: Vec<RawThread>,
}

impl RawProcess {
    /// Жив: у процесса есть потоки. Завершившийся процесс ядро продолжает
    /// перечислять, пока на него держат handle, — без единого потока. Целью
    /// он не бывает, а учёт остановленных обязан увидеть его исчезнувшим.
    pub fn is_alive(&self) -> bool {
        !self.threads.is_empty()
    }

    /// Приостановлен: потоки есть, и все стоят в ожидании с причиной
    /// «приостановлен». Процесс без потоков (завершается) — не стоящий.
    ///
    /// Точность здесь важнее, чем где-либо: план паузы не останавливает уже
    /// стоящий процесс, а счётчик приостановки у потоков Windows копится.
    /// Ложное «идёт» у нашего же стоящего процесса заморозило бы его второй
    /// раз, и одного «продолжить» стало бы мало.
    pub fn is_suspended(&self) -> bool {
        !self.threads.is_empty()
            && self.threads.iter().all(|thread| {
                thread.state == THREAD_STATE_WAITING
                    && (thread.wait_reason == WAIT_REASON_SUSPENDED
                        || thread.wait_reason == WAIT_REASON_WR_SUSPENDED)
            })
    }
}

/// Родитель, которому можно верить. Ядро хранит pid родителя навсегда, а pid
/// переиспользуется: родитель мог завершиться, и его номер достался чужому
/// процессу. Такой «родитель» создан позже ребёнка — и обход потомков утащил
/// бы под охрану чужое дерево. Родитель, которого нет в снимке или который
/// моложе ребёнка, обнуляется.
pub fn trusted_parents(processes: &[RawProcess]) -> HashMap<i32, i32> {
    let created: HashMap<i32, i64> = processes
        .iter()
        .map(|process| (process.pid, process.create_time))
        .collect();
    processes
        .iter()
        .map(|process| {
            let trusted = match created.get(&process.parent_pid) {
                Some(&parent_created)
                    if process.parent_pid != process.pid
                        && parent_created <= process.create_time =>
                {
                    process.parent_pid
                }
                _ => 0,
            };
            (process.pid, trusted)
        })
        .collect()
}

/// `SYSTEM_PROCESS_INFORMATION` по phnt. Размер на 64-битной Windows —
/// 0x100, массив потоков начинается сразу за ней.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct SystemProcessInformation {
    pub next_entry_offset: u32,
    pub number_of_threads: u32,
    pub working_set_private_size: i64,
    pub hard_fault_count: u32,
    pub number_of_threads_high_watermark: u32,
    pub cycle_time: u64,
    pub create_time: i64,
    pub user_time: i64,
    pub kernel_time: i64,
    pub image_name: UnicodeString,
    pub base_priority: i32,
    pub unique_process_id: usize,
    pub inherited_from_unique_process_id: usize,
    pub handle_count: u32,
    pub session_id: u32,
    pub unique_process_key: usize,
    pub peak_virtual_size: usize,
    pub virtual_size: usize,
    pub page_fault_count: u32,
    pub peak_working_set_size: usize,
    pub working_set_size: usize,
    pub quota_peak_paged_pool_usage: usize,
    pub quota_paged_pool_usage: usize,
    pub quota_peak_non_paged_pool_usage: usize,
    pub quota_non_paged_pool_usage: usize,
    pub pagefile_usage: usize,
    pub peak_pagefile_usage: usize,
    pub private_page_count: usize,
    pub read_operation_count: i64,
    pub write_operation_count: i64,
    pub other_operation_count: i64,
    pub read_transfer_count: i64,
    pub write_transfer_count: i64,
    pub other_transfer_count: i64,
}

/// `UNICODE_STRING`: длины в байтах и указатель — указатель здесь не читается.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct UnicodeString {
    pub length: u16,
    pub maximum_length: u16,
    pub buffer: usize,
}

/// `SYSTEM_THREAD_INFORMATION`. Размер на 64-битной Windows — 0x50.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct SystemThreadInformation {
    pub kernel_time: i64,
    pub user_time: i64,
    pub create_time: i64,
    pub wait_time: u32,
    pub start_address: usize,
    pub unique_process: usize,
    pub unique_thread: usize,
    pub priority: i32,
    pub base_priority: i32,
    pub context_switches: u32,
    pub thread_state: u32,
    pub wait_reason: u32,
}

#[cfg(target_pointer_width = "64")]
const _: () = {
    assert!(std::mem::size_of::<SystemProcessInformation>() == 0x100);
    assert!(std::mem::size_of::<SystemThreadInformation>() == 0x50);
    assert!(std::mem::offset_of!(SystemProcessInformation, create_time) == 32);
    assert!(std::mem::offset_of!(SystemProcessInformation, unique_process_id) == 80);
    assert!(std::mem::offset_of!(SystemThreadInformation, thread_state) == 68);
};

/// Записи из буфера. Битый буфер (смещение за край, запись короче своей
/// структуры) обрывает разбор на последней целой записи, а не роняет
/// процесс: снимок неполон, но охрана жива и спросит снова через такт.
///
/// Idle (pid 0) пропускается: это не процесс, а учёт простоя процессора.
pub fn parse(buffer: &[u8]) -> Vec<RawProcess> {
    let process_size = std::mem::size_of::<SystemProcessInformation>();
    let thread_size = std::mem::size_of::<SystemThreadInformation>();
    let mut processes = Vec::new();
    let mut offset = 0usize;
    while let Some(entry) = read::<SystemProcessInformation>(buffer, offset) {
        let threads = (0..entry.number_of_threads as usize)
            .map_while(|index| {
                read::<SystemThreadInformation>(buffer, offset + process_size + index * thread_size)
            })
            .map(|thread| RawThread {
                state: thread.thread_state,
                wait_reason: thread.wait_reason,
            })
            .collect();
        if entry.unique_process_id != 0 {
            processes.push(RawProcess {
                pid: entry.unique_process_id as i32,
                parent_pid: entry.inherited_from_unique_process_id as i32,
                create_time: entry.create_time,
                threads,
            });
        }
        if entry.next_entry_offset == 0 {
            break;
        }
        offset += entry.next_entry_offset as usize;
    }
    processes
}

fn read<T: Copy>(buffer: &[u8], offset: usize) -> Option<T> {
    let end = offset.checked_add(std::mem::size_of::<T>())?;
    let bytes = buffer.get(offset..end)?;
    // SAFETY: длина среза равна размеру `T`, а `T` — `repr(C)` из целых чисел,
    // для которых допустим любой набор байтов; невыровненность снимает
    // `read_unaligned`.
    Some(unsafe { std::ptr::read_unaligned(bytes.as_ptr().cast::<T>()) })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn raw(pid: i32, parent_pid: i32, create_time: i64) -> RawProcess {
        RawProcess {
            pid,
            parent_pid,
            create_time,
            threads: vec![],
        }
    }

    #[test]
    fn a_parent_born_after_its_child_is_someone_else_on_a_reused_pid() {
        let parents = trusted_parents(&[
            raw(100, 4, 10),
            raw(200, 100, 20),
            // Родитель 300 давно умер, его pid получил процесс, созданный позже.
            raw(300, 100, 50),
            raw(400, 300, 30),
        ]);

        assert_eq!(parents[&200], 100);
        assert_eq!(parents[&400], 0, "родитель моложе ребёнка — чужой процесс");
    }

    #[test]
    fn a_parent_missing_from_the_snapshot_is_not_trusted() {
        let parents = trusted_parents(&[raw(200, 100, 20)]);

        assert_eq!(parents[&200], 0);
    }

    #[test]
    fn a_process_is_suspended_only_when_every_thread_is() {
        let suspended = RawThread {
            state: THREAD_STATE_WAITING,
            wait_reason: WAIT_REASON_SUSPENDED,
        };
        let waiting_for_input = RawThread {
            state: THREAD_STATE_WAITING,
            wait_reason: 6,
        };
        let running = RawThread {
            state: 2,
            wait_reason: 0,
        };
        let mut process = raw(1, 0, 0);

        process.threads = vec![suspended, suspended];
        assert!(process.is_suspended());

        process.threads = vec![suspended, waiting_for_input];
        assert!(!process.is_suspended(), "ждать ввода — не стоять");

        process.threads = vec![suspended, running];
        assert!(!process.is_suspended());

        process.threads = vec![];
        assert!(!process.is_suspended(), "без потоков процесс завершается");
        assert!(!process.is_alive(), "завершившийся процесс — не живой");
    }

    #[cfg(target_pointer_width = "64")]
    fn entry(
        next: u32,
        pid: usize,
        parent: usize,
        created: i64,
        threads: &[(u32, u32)],
    ) -> Vec<u8> {
        let mut process: SystemProcessInformation = unsafe { std::mem::zeroed() };
        process.next_entry_offset = next;
        process.number_of_threads = threads.len() as u32;
        process.unique_process_id = pid;
        process.inherited_from_unique_process_id = parent;
        process.create_time = created;
        let mut bytes = as_bytes(&process).to_vec();
        for (state, reason) in threads {
            let mut thread: SystemThreadInformation = unsafe { std::mem::zeroed() };
            thread.thread_state = *state;
            thread.wait_reason = *reason;
            bytes.extend_from_slice(as_bytes(&thread));
        }
        bytes
    }

    #[cfg(target_pointer_width = "64")]
    fn as_bytes<T>(value: &T) -> &[u8] {
        unsafe {
            std::slice::from_raw_parts((value as *const T).cast::<u8>(), std::mem::size_of::<T>())
        }
    }

    #[cfg(target_pointer_width = "64")]
    #[test]
    fn the_buffer_is_walked_by_next_entry_offsets() {
        let idle = entry(0x100, 0, 0, 0, &[]);
        let system = entry(0x100 + 0x50 * 2, 4, 0, 1, &[(5, 5), (5, 5)]);
        let shell = entry(0, 1234, 4, 2, &[(2, 0)]);
        let buffer = [idle, system, shell].concat();

        let processes = parse(&buffer);

        assert_eq!(
            processes
                .iter()
                .map(|p| (p.pid, p.parent_pid, p.create_time))
                .collect::<Vec<_>>(),
            vec![(4, 0, 1), (1234, 4, 2)],
            "Idle (pid 0) — не процесс"
        );
        assert!(processes[0].is_suspended());
        assert!(!processes[1].is_suspended());
    }

    #[cfg(target_pointer_width = "64")]
    #[test]
    fn a_truncated_buffer_keeps_the_whole_entries() {
        let first = entry(0x100, 8, 4, 1, &[]);
        let second = entry(0, 12, 8, 2, &[]);
        let mut buffer = [first, second].concat();
        buffer.truncate(0x100 + 0x40);

        let processes = parse(&buffer);

        assert_eq!(processes.iter().map(|p| p.pid).collect::<Vec<_>>(), vec![8]);
    }
}
