//! Файл статуса, `status`, `check` и `journal`.
//!
//! Охрана считается запущенной по двум признакам сразу — свежести файла и живому
//! pid: процесс, убитый SIGKILL, файл за собой не уберёт, а pid умеет достаться
//! другому.

mod support;

use std::time::{Duration, SystemTime};

use support::{now, Bench, FakeProcesses};
use weto_cli::status::{self, StatusFile};
use weto_config::journal::{Journal, KillEvent, KillEventKind, MatchBasis};
use weto_config::settings::{Settings, Target};
use weto_core::geo::{ConfirmSource, GeoReading};
use weto_core::guard_machine::GuardPhase;
use weto_core::network::{OutgoingRoute, VpnAppStatus, VpnTunnelStatus};
use weto_core::pause_plan::PausedProcess;
use weto_core::policy::{UnprovenReason, UnsafeEvidence};
use weto_core::process::{RunningTarget, TargetKind};
use weto_guard::controller::GuardSnapshot;

fn target(entry: &str) -> Target {
    Target {
        entry: entry.to_string(),
        display_name: entry.to_string(),
        kind: TargetKind::Binary,
        path: format!("/usr/bin/{entry}"),
        launch_paths: vec![],
    }
}

fn tunnel_settings() -> Settings {
    let mut settings = Settings {
        targets: vec![target("claude"), target("codex")],
        ..Settings::default()
    };
    settings.set_vpn_tunnel(Some("wg0".to_string()));
    settings
}

fn kz() -> GeoReading {
    GeoReading {
        ip: "203.0.113.28".to_string(),
        primary_country: "KZ".to_string(),
        confirmed_country: Some("KZ".to_string()),
        confirm_source: Some(ConfirmSource::Freeipapi),
    }
}

fn running(entry: &str, pid: i32) -> RunningTarget {
    RunningTarget {
        entry: entry.to_string(),
        display_name: entry.to_string(),
        kind: TargetKind::Binary,
        path: format!("/usr/bin/{entry}"),
        pid,
        process_count: 1,
    }
}

fn protected_snapshot() -> GuardSnapshot {
    GuardSnapshot {
        phase: GuardPhase::Protected(kz()),
        running: vec![running("claude", 4120), running("claude", 4133)],
        outgoing: Some(OutgoingRoute {
            interface: "wg0".to_string(),
            address: "10.8.0.2".to_string(),
        }),
        vpn_app: Some(VpnAppStatus::NotChosen),
        vpn_tunnel: Some(VpnTunnelStatus::Carrying),
        probed_at: Some(now() - Duration::from_secs(2)),
        ..GuardSnapshot::default()
    }
}

/// Текстовый вид — тот, что описан в задании, строка в строку.
#[test]
fn the_status_of_a_protected_guard_reads_as_specified() {
    let file = status::build(&protected_snapshot(), &tunnel_settings(), 4100, now(), None);

    assert_eq!(
        status::render(&file, now()),
        "Охрана:   На страже — цели работают\n\
         Выход:    203.0.113.28 · KZ, подтверждено freeipapi: KZ\n\
         Трафик:   wg0 (10.8.0.2)\n\
         VPN:      туннель wg0 — несёт трафик\n\
         Цели:     claude — запущено 2 (pid 4120, 4133)\n\
         \x20         codex — не запущено\n\
         Таймаут:  подтверждение ждётся 1 мин\n"
    );
}

/// Формат файла общий с macOS: ключи в camelCase, пустое — `null`, а не пропуск.
#[test]
fn the_status_file_names_every_field_and_writes_null_for_nothing() {
    let mut snapshot = protected_snapshot();
    snapshot.outgoing = None;
    snapshot.probed_at = None;
    let file = status::build(&snapshot, &tunnel_settings(), 4100, now(), None);

    let json: serde_json::Value = serde_json::to_value(&file).unwrap();

    for key in [
        "version",
        "pid",
        "updatedAt",
        "lastProbeAt",
        "phase",
        "pauseDeadline",
        "reading",
        "outgoing",
        "vpn",
        "targets",
        "pauseCeilingSeconds",
        "updateAvailable",
    ] {
        assert!(json.get(key).is_some(), "нет ключа {key}");
    }
    assert!(json["updateAvailable"].is_null());
    assert_eq!(json["version"], 1);
    assert!(json["lastProbeAt"].is_null());
    assert!(json["outgoing"].is_null());
    assert!(json["pauseDeadline"].is_null());
    assert_eq!(json["updatedAt"], "2027-01-15T08:00:00Z");
    assert_eq!(json["phase"]["kind"], "protected");
    assert_eq!(json["phase"]["title"], "На страже");
    assert_eq!(json["phase"]["action"], "цели работают");
    assert_eq!(json["reading"]["confirmedCountry"], "KZ");
    assert_eq!(json["reading"]["confirmSource"], "freeipapi");
    assert_eq!(json["vpn"]["kind"], "tunnel");
    assert_eq!(json["vpn"]["name"], "wg0");
    assert_eq!(json["vpn"]["status"], "carrying");
    assert!(json["vpn"]["via"].is_null());
    assert_eq!(json["targets"][0]["running"][1], 4133);
    assert_eq!(json["pauseCeilingSeconds"], 60);
}

/// Новая версия от суточной проверки — в файле и строкой «Обновление:»
/// в конце статуса; нечего сказать — строки нет.
#[test]
fn an_available_update_is_named_in_the_file_and_the_text() {
    let file = status::build(
        &protected_snapshot(),
        &tunnel_settings(),
        4100,
        now(),
        Some("0.3.0".to_string()),
    );

    let json: serde_json::Value = serde_json::to_value(&file).unwrap();
    assert_eq!(json["updateAvailable"], "0.3.0");
    assert!(status::render(&file, now())
        .ends_with("Таймаут:  подтверждение ждётся 1 мин\nОбновление: доступна версия 0.3.0 — sudo weto update\n"));

    let quiet = status::build(&protected_snapshot(), &tunnel_settings(), 4100, now(), None);
    assert!(!status::render(&quiet, now()).contains("Обновление"));
}

/// Файл статуса читается без sudo — системный тоже.
#[test]
fn the_status_file_is_readable_by_everyone() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("status.json");
    let file = status::build(&protected_snapshot(), &tunnel_settings(), 4100, now(), None);

    status::write(&path, &file).unwrap();

    let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o644, "права: {mode:o}");
}

/// Файл прежней охраны — без `updateAvailable` — читается как «нечего сказать».
#[test]
fn a_status_file_without_the_update_field_still_reads() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("status.json");
    let file = status::build(&protected_snapshot(), &tunnel_settings(), 4100, now(), None);
    let mut json = serde_json::to_value(&file).unwrap();
    json.as_object_mut().unwrap().remove("updateAvailable");
    std::fs::write(&path, json.to_string()).unwrap();

    assert_eq!(status::read(&path), Some(file));
}

#[test]
fn every_phase_has_its_kind() {
    let cases = [
        (GuardPhase::Disabled, "disabled"),
        (
            GuardPhase::Verifying {
                cause: weto_core::diagnostics::StalenessCause::ColdStart,
            },
            "verifying",
        ),
        (GuardPhase::Protected(kz()), "protected"),
        (
            GuardPhase::Interference {
                reading: kz(),
                reason: UnprovenReason::ConfirmationUnavailable,
            },
            "interference",
        ),
        (
            GuardPhase::Paused {
                since: now(),
                reason: UnprovenReason::ConfirmationUnavailable,
            },
            "paused",
        ),
        (
            GuardPhase::Danger(UnsafeEvidence::VpnTunnelDown("wg0".to_string())),
            "danger",
        ),
    ];
    for (phase, kind) in cases {
        assert_eq!(status::phase_kind(&phase), kind);
    }
}

/// Под паузой — отсчёт до потолка и подсказка про `fg` у цели, ушедшей в фон;
/// стоящие процессы «запущенными» не считаются.
#[test]
fn a_paused_status_counts_down_and_hints_at_fg() {
    let since = now() - Duration::from_secs(17);
    let snapshot = GuardSnapshot {
        phase: GuardPhase::Paused {
            since,
            reason: UnprovenReason::ConfirmationUnavailable,
        },
        running: vec![running("claude", 4120)],
        paused: vec![PausedProcess {
            pid: 4120,
            target_name: "claude".to_string(),
            since,
            is_backgrounded: true,
        }],
        pause_deadline: Some(since + Duration::from_secs(60)),
        vpn_tunnel: Some(VpnTunnelStatus::Carrying),
        ..GuardSnapshot::default()
    };
    let file = status::build(&snapshot, &tunnel_settings(), 4100, now(), None);

    assert!(
        file.targets[0].running.is_empty(),
        "стоящая — не запущенная"
    );
    assert_eq!(file.targets[0].paused, [4120]);
    let text = status::render(&file, now());
    assert!(
        text.contains("Охрана:   Выход не подтверждён — цели остановлены\n"),
        "{text}"
    );
    assert!(
        text.contains("Причина:  Подтверждающие сервисы недоступны\n"),
        "{text}"
    );
    assert!(text.contains("Пауза:    43 с до завершения"), "{text}");
    assert!(text.contains("claude — на паузе (pid 4120)"), "{text}");
    assert!(text.contains("введите fg"), "{text}");
}

/// Состояния VPN словами: туннель упал, трафик мимо, приложение, не задан.
#[test]
fn the_vpn_line_names_the_state() {
    let mut snapshot = protected_snapshot();
    snapshot.phase = GuardPhase::Danger(UnsafeEvidence::TrafficBypassesTunnel {
        tunnel: "wg0".to_string(),
        via: "eth0".to_string(),
    });
    snapshot.vpn_tunnel = Some(VpnTunnelStatus::Bypassed {
        via: "eth0".to_string(),
    });
    let file = status::build(&snapshot, &tunnel_settings(), 1, now(), None);
    assert_eq!(file.vpn.status, "bypassed");
    assert_eq!(file.vpn.via.as_deref(), Some("eth0"));
    let text = status::render(&file, now());
    assert!(text.contains("туннель wg0 — поднят, но трафик идёт мимо, через eth0"));
    assert!(text.contains("Причина:  трафик идёт мимо туннеля wg0 — через eth0"));

    snapshot.vpn_tunnel = Some(VpnTunnelStatus::Down);
    let file = status::build(&snapshot, &tunnel_settings(), 1, now(), None);
    assert_eq!(file.vpn.status, "down");

    let mut app = Settings::default();
    app.set_vpn_app(Some(target("happ")));
    snapshot.vpn_app = Some(VpnAppStatus::NotRunning);
    let file = status::build(&snapshot, &app, 1, now(), None);
    assert_eq!(
        (file.vpn.kind.as_str(), file.vpn.status.as_str()),
        ("app", "notRunning")
    );
    assert!(status::render(&file, now()).contains("приложение happ — не запущено"));

    let file = status::build(&snapshot, &Settings::default(), 1, now(), None);
    assert_eq!(
        (file.vpn.kind.as_str(), file.vpn.status.as_str()),
        ("none", "notChosen")
    );
}

#[test]
fn the_status_file_round_trips_through_disk() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("state/status.json");
    let file = status::build(&protected_snapshot(), &tunnel_settings(), 4100, now(), None);

    status::write(&path, &file).unwrap();

    assert_eq!(status::read(&path), Some(file));
    assert!(!dir.path().join("state/status.json.tmp").exists());
}

// --- запущена ли охрана -----------------------------------------------------------

fn written(bench: &Bench, updated_at: SystemTime, pid: i32) -> StatusFile {
    let mut file = status::build(
        &protected_snapshot(),
        &tunnel_settings(),
        pid,
        updated_at,
        None,
    );
    file.updated_at = updated_at;
    status::write(&bench.ctx.paths.status_file(), &file).unwrap();
    file
}

#[test]
fn a_fresh_file_of_a_live_process_means_running() {
    let mut bench = Bench::new();
    bench.ctx.processes = Box::new(FakeProcesses::alive(&[4100]));
    written(&bench, now() - Duration::from_secs(3), 4100);

    let output = bench.run(&["status"]);

    assert_eq!(output.code, 0, "{}", output.out);
    assert!(output.out.starts_with("Охрана:   На страже"));
    let json = bench.run(&["status", "--json"]);
    assert_eq!(json.code, 0);
    let parsed: serde_json::Value = serde_json::from_str(&json.out).unwrap();
    assert_eq!(parsed["pid"], 4100);
}

/// Файл остался от процесса, убитого SIGKILL: старше десяти секунд — не запущена.
#[test]
fn a_stale_file_means_not_running() {
    let mut bench = Bench::new();
    bench.ctx.processes = Box::new(FakeProcesses::alive(&[4100]));
    written(&bench, now() - Duration::from_secs(11), 4100);

    let output = bench.run(&["status"]);

    assert_eq!(output.code, 3);
    assert!(output
        .out
        .starts_with("Охрана не запущена: weto run или weto service install\n"));
}

/// Свежий файл, но процесса нет: pid мог достаться другому — не запущена.
#[test]
fn a_dead_pid_means_not_running() {
    let bench = Bench::new();
    written(&bench, now(), 4100);

    let output = bench.run(&["status"]);

    assert_eq!(output.code, 3);
    assert_eq!(bench.run(&["status", "--json"]).code, 3);
}

/// Не запущена — сводка настроек: пользователь видит, что охрана сделала бы.
#[test]
fn not_running_prints_a_summary_of_the_settings() {
    let bench = Bench::new();
    tunnel_settings()
        .save(&bench.ctx.paths.settings_file())
        .unwrap();

    let output = bench.run(&["status"]);

    assert_eq!(output.code, 3);
    assert!(
        output.out.contains("VPN:      туннель wg0\n"),
        "{}",
        output.out
    );
    assert!(
        output.out.contains("Цели:     claude, codex\n"),
        "{}",
        output.out
    );
    assert!(output.out.contains("Токен:    не задан\n"));
}

// --- check ----------------------------------------------------------------------

/// Охрана запущена: просьба уходит ей сигналом, а ответ — новая отметка пробы
/// в её статусе.
#[test]
fn check_asks_the_running_guard_and_waits_for_its_probe() {
    let mut bench = Bench::new();
    let processes = FakeProcesses::alive(&[4100]);
    bench.ctx.processes = Box::new(processes.clone());
    let before = written(&bench, now(), 4100);
    let path = bench.ctx.paths.status_file();
    processes.answers_with(move || {
        let mut answered = before.clone();
        answered.last_probe_at = Some(now() + Duration::from_secs(1));
        status::write(&path, &answered).unwrap();
    });

    let output = bench.run(&["check"]);

    assert_eq!(output.code, 0, "{}", output.err);
    assert_eq!(processes.asked(), [4100]);
    assert_eq!(
        bench.geo.calls(),
        0,
        "проба — у охраны, не у этого процесса"
    );
    assert!(output.out.starts_with("Охрана:   На страже"));
}

#[test]
fn check_gives_up_after_fifteen_seconds() {
    let mut bench = Bench::new();
    let processes = FakeProcesses::alive(&[4100]);
    bench.ctx.processes = Box::new(processes.clone());
    let file = written(&bench, now(), 4100);
    // Охрана жива и пишет статус, но проба всё не возвращается: отметка
    // обновления впереди часов стенда, отметка пробы прежняя.
    let path = bench.ctx.paths.status_file();
    processes.answers_with(move || {
        let mut alive = file.clone();
        alive.updated_at = now() + Duration::from_secs(20);
        status::write(&path, &alive).unwrap();
    });

    let output = bench.run(&["check"]);

    assert_eq!(output.code, 1, "{}", output.out);
    assert!(output.err.contains("ответа проверки не дождался за 15 с"));
    let waited = weto_cli::context::Clock::now(&bench.clock)
        .duration_since(now())
        .unwrap();
    assert!(waited >= Duration::from_secs(15) && waited < Duration::from_secs(16));
}

/// Охрана не запущена: одна проба здесь, вердикт печатается, а не исполняется.
#[test]
fn check_without_a_guard_probes_once_and_signals_nobody() {
    let bench = Bench::new();
    let mut settings = tunnel_settings();
    settings.blocked_countries = vec!["RU".to_string()];
    settings.save(&bench.ctx.paths.settings_file()).unwrap();
    *bench.network.0.lock().unwrap() = support::FakeNetwork::tunnel().0.lock().unwrap().clone();

    let output = bench.run(&["check"]);

    assert_eq!(output.code, 3);
    assert_eq!(bench.geo.calls(), 1);
    assert!(bench.processes.asked().is_empty());
    assert!(output.out.contains("выход безопасен"), "{}", output.out);
    assert!(
        output.out.contains("VPN:      туннель wg0 — несёт трафик"),
        "{}",
        output.out
    );
    assert!(
        !bench.ctx.paths.journal_file().exists(),
        "журналы не трогаются"
    );
    assert!(
        !bench.ctx.paths.stopped_file().exists(),
        "учёт не трогается"
    );
}

#[test]
fn check_without_a_guard_names_the_local_evidence() {
    let bench = Bench::new();
    tunnel_settings()
        .save(&bench.ctx.paths.settings_file())
        .unwrap();

    let output = bench.run(&["check"]);

    assert_eq!(output.code, 3);
    assert!(
        output
            .out
            .contains("VPN-туннель wg0 не поднят — работающая охрана завершила бы цели"),
        "{}",
        output.out
    );
}

// --- journal --------------------------------------------------------------------

fn event(pid: i32, seconds: u64) -> KillEvent {
    KillEvent {
        id: format!("e-{pid}"),
        episode_id: "e".to_string(),
        at: SystemTime::UNIX_EPOCH + Duration::from_secs(seconds),
        target_name: "claude".to_string(),
        pid,
        parent_pid: 1,
        executable_path: "/usr/bin/claude".to_string(),
        matched_by: MatchBasis::Rule,
        kind: KillEventKind::Paused,
        reason_text: "VPN-туннель wg0 не поднят".to_string(),
        resolution_text: Some("возобновлено проверкой".to_string()),
        ip: None,
        country: None,
        confirmed_country: None,
        confirm_source: None,
        diagnostics: None,
    }
}

#[test]
fn the_journal_shows_the_latest_twenty_newest_first() {
    let bench = Bench::new();
    let mut journal = Journal::default();
    for pid in 0..25 {
        journal.append(vec![event(pid, 1_000 + pid as u64)]);
    }
    journal.save(&bench.ctx.paths.journal_file()).unwrap();

    let output = bench.run(&["journal"]);

    assert_eq!(output.code, 0);
    let records: Vec<&str> = output
        .out
        .lines()
        .filter(|line| line.contains("claude · pid"))
        .collect();
    assert_eq!(records.len(), 20);
    assert!(
        records[0].contains("pid 24"),
        "свежие первыми: {}",
        records[0]
    );
    assert!(output.out.contains("на паузе — VPN-туннель wg0 не поднят"));
    assert!(output.out.contains("Итог: возобновлено проверкой"));
    assert!(output
        .out
        .contains("Показаны последние 20 из 25 — выгрузите журнал целиком"));
}

/// `--json` — та же выгрузка, что «Выгрузить журнал» в окне; токена в ней нет.
#[test]
fn the_journal_export_is_the_shared_format_without_the_token() {
    let bench = Bench::new();
    let mut journal = Journal::default();
    journal.append(vec![event(7, 1_000)]);
    journal.save(&bench.ctx.paths.journal_file()).unwrap();
    bench.run(&["token", "set", "secret-3"]);

    let output = bench.run(&["journal", "--json"]);

    assert_eq!(output.code, 0);
    assert!(!output.out.contains("secret-3"));
    let parsed: serde_json::Value = serde_json::from_str(&output.out).unwrap();
    assert_eq!(parsed["settings"]["hasIPInfoToken"], true);
    assert_eq!(parsed["events"][0]["pid"], 7);
    assert_eq!(parsed["app"]["platform"], "Linux");
}

#[test]
fn an_empty_journal_says_so() {
    assert_eq!(Bench::new().run(&["journal"]).out, "Журнал пуст\n");
}
