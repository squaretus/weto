//! Адаптеры на настоящей Windows: процессы, сигналы, сеть, учётные данные,
//! реестр. Подделать здесь нечего — именно эти вызовы решают судьбу целей,
//! поэтому тесты идут к живому ядру и порождают настоящие процессы.
//!
//! Идут на раннерах Windows в CI; на других системах файла нет.
#![cfg(windows)]

use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use weto_core::path_text::same_path;
use weto_core::process::{ProcessSnapshot, TargetKind};
use weto_sys::network_snapshot::{InterfaceListing, KernelRouteProbe};
use weto_sys::process_registry::ProcessRegistryReading;
use weto_sys::process_signaler::{ProcessSignal, ProcessSignaling, PROCESS_GONE};
use weto_sys::secret_store::SecretStoring;
use weto_sys::target_resolver::TargetResolving;
use weto_sys_windows::autostart::RunKeyAutostart;
use weto_sys_windows::interfaces::AdapterInterfaces;
use weto_sys_windows::process_registry::NtProcessRegistry;
use weto_sys_windows::process_signaler::WindowsProcessSignaler;
use weto_sys_windows::secret_store::CredentialStore;
use weto_sys_windows::target_resolver::{without_verbatim_prefix, WindowsTargetResolver};

/// Долгий консольный процесс: `ping` на петлю — есть на любой Windows.
fn pinging(seconds: u32) -> Child {
    Command::new("ping")
        .args(["-n", &seconds.to_string(), "127.0.0.1"])
        .stdout(Stdio::null())
        .spawn()
        .expect("ping не запустился")
}

fn find(registry: &NtProcessRegistry, pid: u32) -> Option<ProcessSnapshot> {
    registry
        .snapshot()
        .into_iter()
        .find(|process| process.pid == pid as i32)
}

/// Ждать, пока состояние процесса станет нужным: приостановка доходит до потоков
/// не мгновенно.
fn eventually_stopped(registry: &NtProcessRegistry, pid: u32, stopped: bool) -> bool {
    let deadline = Instant::now() + Duration::from_secs(3);
    while Instant::now() < deadline {
        if find(registry, pid).is_some_and(|process| process.is_stopped == stopped) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    false
}

/// Урок macOS: обход отдавал четверть списка — свежую, и все тесты, порождавшие
/// процесс за миг до обхода, проходили. Здесь проверяется процесс, живущий
/// дольше теста, — сам раннер тестов и его родитель. Заодно сверяется раскладка
/// структур: pid, родитель и путь своего процесса обязаны прочитаться верно.
#[test]
fn the_snapshot_holds_processes_older_than_the_test() {
    let registry = NtProcessRegistry::new();
    let processes = registry.snapshot();
    let me = processes
        .iter()
        .find(|process| process.pid == std::process::id() as i32)
        .expect("своего процесса в снимке нет");

    let exe = std::env::current_exe().unwrap();
    let exe = without_verbatim_prefix(&std::fs::canonicalize(exe).unwrap().to_string_lossy());
    assert!(
        same_path(&me.executable_path, &exe),
        "{} != {exe}",
        me.executable_path
    );
    assert!(me.parent_pid > 0, "родитель раннера тестов обязан найтись");
    assert!(
        processes.iter().any(|process| process.pid == me.parent_pid),
        "родитель старше теста, и его нет в снимке"
    );
    assert!(
        processes.len() > 20,
        "подозрительно мало процессов: {}",
        processes.len()
    );
    assert!(processes.iter().all(|p| p.terminal_foreground_group == 0));
}

#[test]
fn the_command_line_and_the_parent_are_read() {
    let registry = NtProcessRegistry::new();
    let mut child = pinging(30);

    let process = find(&registry, child.id()).expect("ping не найден");
    child.kill().ok();
    child.wait().ok();

    assert!(process
        .executable_path
        .to_ascii_lowercase()
        .ends_with(r"\ping.exe"));
    assert_eq!(process.parent_pid, std::process::id() as i32);
    let arguments = process.arguments.expect("командная строка не прочиталась");
    assert_eq!(&arguments[1..], ["-n", "30", "127.0.0.1"]);
    assert!(!process.is_stopped);
}

/// Пауза, продолжение и завершение — с наблюдением за ядром, а не по коду
/// возврата: `NtSuspendProcess` вернул бы успех и тогда, когда стоять процесс
/// не стал.
#[test]
fn a_process_is_paused_resumed_and_terminated() {
    let registry = NtProcessRegistry::new();
    let signaler = WindowsProcessSignaler;
    let mut child = pinging(60);
    let pid = child.id() as i32;

    let stop = signaler.send(ProcessSignal::Stop, &[pid]);
    assert_eq!(stop[0].error_code, None);
    assert!(eventually_stopped(&registry, child.id(), true), "не встал");

    let resume = signaler.send(ProcessSignal::Resume, &[pid]);
    assert_eq!(resume[0].error_code, None);
    assert!(eventually_stopped(&registry, child.id(), false), "не пошёл");

    // Стоящий процесс завершается так же, как идущий: обработчика у него нет.
    signaler.send(ProcessSignal::Stop, &[pid]);
    let kill = signaler.send(ProcessSignal::Kill, &[pid]);
    assert_eq!(kill[0].error_code, None);
    let status = child.wait().unwrap();
    assert!(!status.success());
}

/// Консольная программа после паузы доделывает своё и выходит с успехом:
/// консоль её не теряет (на Linux тут ловушки tmux и SIGTTIN, здесь их нет).
#[test]
fn a_console_program_finishes_normally_after_a_pause() {
    let signaler = WindowsProcessSignaler;
    let mut child = pinging(3);
    let pid = child.id() as i32;

    signaler.send(ProcessSignal::Stop, &[pid]);
    std::thread::sleep(Duration::from_secs(2));
    signaler.send(ProcessSignal::Resume, &[pid]);

    assert!(child.wait().unwrap().success());
}

/// Процесса нет — сигнал считается доставленным: цель достигнута. Отказ вызова
/// (pid 0) — не доставка.
#[test]
fn a_vanished_process_counts_as_delivered_and_pid_zero_is_refused() {
    let signaler = WindowsProcessSignaler;
    let mut child = pinging(1);
    let pid = child.id() as i32;
    child.wait().unwrap();
    drop(child);

    let gone = signaler.send(ProcessSignal::Stop, &[pid]);
    assert!(
        gone[0].is_delivered(),
        "ожидался код {PROCESS_GONE}, пришёл {:?}",
        gone[0].error_code
    );
    assert!(!signaler.send(ProcessSignal::Kill, &[0])[0].is_delivered());
}

/// Проба маршрута называет тот же интерфейс, что сама Windows, а список поднятых
/// интерфейсов называет его тем же именем.
#[test]
fn the_route_probe_agrees_with_windows() {
    let Some(probed) = KernelRouteProbe::default().route_to("1.1.1.1") else {
        return;
    };
    let output = Command::new("powershell")
        .args([
            "-NoProfile",
            "-Command",
            "(Find-NetRoute -RemoteIPAddress 1.1.1.1 | Select-Object -First 1).InterfaceAlias",
        ])
        .output()
        .unwrap();
    let expected = String::from_utf8_lossy(&output.stdout).trim().to_string();

    assert_eq!(probed.interface, expected);
    assert!(
        AdapterInterfaces
            .up_interfaces()
            .contains(&probed.interface),
        "{} нет среди поднятых: {:?}",
        probed.interface,
        AdapterInterfaces.up_interfaces()
    );
}

#[test]
fn a_token_round_trips_through_the_credential_manager() {
    let store = CredentialStore::new(&format!("com.weto.test.{}", std::process::id()));

    store.save("секрет-123").unwrap();
    assert_eq!(store.load().unwrap().as_deref(), Some("секрет-123"));
    store.delete().unwrap();
    assert_eq!(store.load().unwrap(), None);
    store.delete().expect("удалить отсутствующее — не ошибка");
}

#[test]
fn autostart_is_one_value_in_the_run_key() {
    let autostart = RunKeyAutostart::new(&format!("WetoTest{}", std::process::id()));
    let launcher =
        std::path::Path::new(r"C:\Users\Тест Пользователь\AppData\Local\Programs\weto\Weto.exe");

    autostart.enable(launcher).unwrap();
    assert_eq!(
        autostart.command().as_deref(),
        Some(r#""C:\Users\Тест Пользователь\AppData\Local\Programs\weto\Weto.exe""#)
    );
    autostart.disable().unwrap();
    assert_eq!(autostart.command(), None);
    autostart
        .disable()
        .expect("выключить выключенное — не ошибка");
}

#[test]
fn the_process_opts_out_of_power_throttling() {
    weto_sys_windows::power::keep_full_speed().unwrap();
}

#[test]
fn a_bare_system_command_is_found_by_path_and_pathext() {
    let located = WindowsTargetResolver.locate("cmd").expect("cmd не найден");

    assert_eq!(located.kind, TargetKind::Binary);
    assert!(located
        .path
        .to_ascii_lowercase()
        .ends_with(r"\system32\cmd.exe"));
    assert_eq!(
        WindowsTargetResolver.kind_of(&located.path),
        Some(TargetKind::Binary)
    );
}
