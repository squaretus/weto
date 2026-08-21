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
        vpn_app: Some(Target {
            entry: "happ".to_string(),
            display_name: "happ".to_string(),
            kind: TargetKind::Binary,
            path: "/usr/bin/happ".to_string(),
            launch_paths: vec![],
        }),
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
        vpn_app: Some(Target {
            entry: "happ".to_string(),
            display_name: "happ".to_string(),
            kind: TargetKind::Binary,
            path: "/usr/bin/happ".to_string(),
            launch_paths: vec![],
        }),
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

/// Причина эпизода, ставшая известной, дописывается в его запись: fail-closed
/// пишет «ещё не проверено» раньше вердикта, а второй записи не будет — цели
/// к тому моменту уже мертвы.
#[test]
fn journal_refines_the_reason_of_the_last_entry() {
    let mut journal = Journal::default();
    journal.append(event(7, "Подключение ещё не проверено"));

    assert!(journal.refine_last_reason("Адрес 185.228.113.231 в чёрном списке"));

    assert_eq!(journal.entries().len(), 1);
    assert_eq!(
        journal.entries()[0].reason_text,
        "Адрес 185.228.113.231 в чёрном списке"
    );
    assert_eq!(journal.entries()[0].killed_pids, vec![7]);
}

#[test]
fn refining_an_empty_journal_changes_nothing() {
    let mut journal = Journal::default();
    assert!(!journal.refine_last_reason("Адрес в чёрном списке"));
    assert!(journal.entries().is_empty());
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
}

/// Разбор записи чёрного списка живёт в настройках, а не в окне: мусор
/// не должен молча попадать в файл и висеть там как «не разобран».
#[test]
fn a_blacklist_entry_is_parsed_before_it_is_stored() {
    let mut settings = Settings::default();

    assert!(settings.add_blocked_entry("ru").is_ok());
    assert!(settings.add_blocked_entry("185.228.113.231").is_ok());
    assert!(settings.add_blocked_entry("10.0.0.0/8").is_ok());

    // Код страны приводится к верхнему регистру: политика сравнивает именно так.
    assert_eq!(settings.blocked_countries, ["RU"]);
    assert_eq!(settings.blocked_ip_ranges.len(), 2);
    assert_eq!(settings.blocked_entries().len(), 3);

    assert_eq!(
        settings.add_blocked_entry("не адрес"),
        Err(weto_config::settings::BlacklistEntryError::InvalidEntry)
    );
    assert_eq!(
        settings.add_blocked_entry("  "),
        Err(weto_config::settings::BlacklistEntryError::Empty)
    );
    assert_eq!(
        settings.add_blocked_entry("RU"),
        Err(weto_config::settings::BlacklistEntryError::Duplicate)
    );
}

#[test]
fn removing_a_blacklist_entry_does_not_care_which_list_it_came_from() {
    let mut settings = Settings::default();
    settings.add_blocked_entry("RU").unwrap();
    settings.add_blocked_entry("10.0.0.0/8").unwrap();

    settings.remove_blocked_entry("RU");
    settings.remove_blocked_entry("10.0.0.0/8");

    assert!(settings.blocked_entries().is_empty());
}

/// Выбор VPN-приложения снимает его же из целей: охрана не имеет права
/// завершать собственный источник защиты.
#[test]
fn choosing_a_vpn_app_removes_it_from_the_targets() {
    let app = Target {
        entry: "happ".to_string(),
        display_name: "happ".to_string(),
        kind: TargetKind::Binary,
        path: "/usr/bin/happ".to_string(),
        launch_paths: vec![],
    };
    let mut settings = Settings {
        targets: vec![
            Target {
                entry: "nano".to_string(),
                display_name: "nano".to_string(),
                kind: TargetKind::Binary,
                path: "/usr/bin/nano".to_string(),
                launch_paths: vec![],
            },
            app.clone(),
        ],
        ..Default::default()
    };

    settings.set_vpn_app(Some(app));

    assert_eq!(
        settings
            .targets
            .iter()
            .map(|t| t.entry.as_str())
            .collect::<Vec<_>>(),
        vec!["nano"]
    );
    assert!(settings.vpn_app_rule().is_some());
}
