//! Настройки, журнал и пути XDG.

use std::time::SystemTime;

use weto_config::journal::{Journal, KillEvent, KillEventKind, CAPACITY};
use weto_config::paths::Paths;
use weto_config::settings::{Settings, Target};
use weto_core::process::TargetKind;

fn event(pid: i32, reason: &str) -> KillEvent {
    KillEvent {
        at: SystemTime::UNIX_EPOCH,
        target_names: vec!["nano".to_string()],
        kind: KillEventKind::Terminated,
        reason_text: reason.to_string(),
        ip: None,
        country: None,
        confirmed_country: None,
        confirm_source: None,
        killed_pids: vec![pid],
    }
}

#[test]
fn settings_survive_a_round_trip() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("weto/config.toml");

    let settings = Settings {
        vpn_interface: Some("wg0".to_string()),
        blocked_countries: vec!["RU".to_string()],
        blocked_ip_ranges: vec!["10.0.0.0/8".to_string()],
        targets: vec![Target {
            entry: "/usr/bin/nano".to_string(),
            display_name: "nano".to_string(),
            kind: TargetKind::Binary,
            path: "/usr/bin/nano".to_string(),
            launch_paths: vec![],
        }],
        revision: 7,
        ..Default::default()
    };

    settings.save(&path).unwrap();

    assert_eq!(Settings::load(&path).unwrap(), settings);
}

/// Токен живёт отдельно и с правами 0600. Конфиг читается любым процессом
/// пользователя и уезжает в бэкапы — секрету там не место.
#[test]
fn the_token_never_reaches_the_settings_file() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("config.toml");

    let settings = Settings {
        vpn_interface: Some("wg0".to_string()),
        ..Default::default()
    };
    settings.save(&path).unwrap();

    let text = std::fs::read_to_string(&path).unwrap();
    assert!(!text.contains("token"), "в файле оказалось: {text}");
}

#[test]
fn a_missing_settings_file_is_a_fresh_install_not_an_error() {
    let tmp = tempfile::tempdir().unwrap();
    let settings = Settings::load(&tmp.path().join("нет-такого.toml")).unwrap();

    assert_eq!(settings, Settings::default());
    assert!(settings.is_enabled, "охрана включена по умолчанию");
}

#[test]
fn a_corrupt_settings_file_is_reported_not_silently_replaced() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("config.toml");
    std::fs::write(&path, "это не toml = = =").unwrap();

    assert!(
        Settings::load(&path).is_err(),
        "молча подменять настройки умолчаниями значило бы стереть цели пользователя"
    );
}

/// Неразбираемый диапазон, вписанный в файл руками, не должен ронять охрану:
/// она обязана продолжать охранять по остальным правилам.
#[test]
fn a_broken_ip_range_does_not_disarm_the_guard() {
    let settings = Settings {
        blocked_ip_ranges: vec!["10.0.0.0/8".into(), "не диапазон".into()],
        ..Default::default()
    };

    let config = settings.guard_config();

    assert_eq!(config.blocked_ip_ranges.len(), 1);
    assert!(config.blocked_ip_ranges[0].contains("10.1.2.3"));
}

#[test]
fn target_rules_keep_the_launch_path_and_its_resolution() {
    let settings = Settings {
        targets: vec![Target {
            entry: "qwen".to_string(),
            display_name: "qwen".to_string(),
            kind: TargetKind::Script,
            path: "/opt/qwen/bin/qwen.js".to_string(),
            launch_paths: vec!["/usr/local/bin/qwen".to_string()],
        }],
        ..Default::default()
    };

    let rules = settings.target_rules();

    assert_eq!(
        rules[0].launch_paths,
        vec!["/opt/qwen/bin/qwen.js", "/usr/local/bin/qwen"]
    );
}

#[test]
fn journal_keeps_the_last_ten_entries() {
    let mut journal = Journal::default();
    for pid in 0..15 {
        journal.append(event(pid, "VPN не поднят"));
    }

    assert_eq!(journal.entries().len(), CAPACITY);
    assert_eq!(journal.entries()[0].killed_pids, vec![5]);
    assert_eq!(journal.entries()[9].killed_pids, vec![14]);
}

#[test]
fn journal_survives_a_round_trip() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("state/journal.json");

    let mut journal = Journal::default();
    journal.append(event(42, "VPN не поднят"));
    journal.save(&path).unwrap();

    assert_eq!(Journal::load(&path), journal);
}

/// Журнал — история, а не данные. Испорченный файл не должен мешать охране.
#[test]
fn a_corrupt_journal_reads_as_empty() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("journal.json");
    std::fs::write(&path, "{ поломка").unwrap();

    assert!(Journal::load(&path).entries().is_empty());
}

#[test]
fn summary_lowercases_the_first_word_but_spares_abbreviations() {
    let vpn = event(1, "VPN не поднят");
    let geo = event(1, "Подтверждающие сервисы недоступны");

    assert_eq!(vpn.summary_text(), "завершено — VPN не поднят");
    assert_eq!(
        geo.summary_text(),
        "завершено — подтверждающие сервисы недоступны"
    );
}

#[test]
fn nameless_target_still_reads_as_something() {
    let mut nameless = event(1, "VPN не поднят");
    nameless.target_names.clear();

    assert_eq!(nameless.targets_text(), "неизвестная цель");
}

#[test]
fn paths_follow_xdg_layout_under_a_given_home() {
    let paths = Paths::rooted("/дом".into());

    assert_eq!(
        paths.settings_file(),
        std::path::Path::new("/дом/.config/weto/config.toml")
    );
    assert_eq!(
        paths.journal_file(),
        std::path::Path::new("/дом/.local/state/weto/journal.json")
    );
    assert_eq!(
        paths.flags_cache_dir(),
        std::path::Path::new("/дом/.cache/weto/flags-circle")
    );
}
