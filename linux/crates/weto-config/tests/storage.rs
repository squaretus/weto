//! Настройки, журнал и пути XDG.

use std::time::SystemTime;

use weto_config::journal::{Journal, KillEvent, KillEventKind, CAPACITY};
use weto_config::paths::Paths;
use weto_config::settings::{GeoListEntryError, GeoListKind, Settings, Target};
use weto_core::process::TargetKind;

fn event(pid: i32, reason: &str) -> KillEvent {
    episode_event(pid, reason, "эпизод")
}

fn episode_event(pid: i32, reason: &str, episode_id: &str) -> KillEvent {
    KillEvent {
        id: format!("{episode_id}-{pid}"),
        episode_id: episode_id.to_string(),
        at: SystemTime::UNIX_EPOCH,
        target_name: "nano".to_string(),
        pid,
        parent_pid: 1,
        executable_path: "/usr/bin/nano".to_string(),
        is_descendant: false,
        kind: KillEventKind::Terminated,
        reason_text: reason.to_string(),
        resolution_text: None,
        ip: None,
        country: None,
        confirmed_country: None,
        confirm_source: None,
        diagnostics: None,
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

/// Сто записей, а не десять: запись теперь на процесс, и одно падение VPN
/// на тридцати четырёх процессах вытесняло прежний журнал целиком.
#[test]
fn journal_keeps_the_last_hundred_entries() {
    assert_eq!(CAPACITY, 100);

    let mut journal = Journal::default();
    for pid in 0..(CAPACITY as i32 + 5) {
        journal.append(vec![event(pid, "VPN не поднят")]);
    }

    assert_eq!(journal.entries().len(), CAPACITY);
    assert_eq!(journal.entries()[0].pid, 5);
    assert_eq!(journal.entries()[CAPACITY - 1].pid, CAPACITY as i32 + 4);
}

/// Проход охраны пишется целиком: завершили четыре процесса — четыре записи,
/// а не одна строка с четырьмя pid внутри.
#[test]
fn a_pass_is_written_as_a_record_per_process() {
    let mut journal = Journal::default();
    journal.append(vec![
        episode_event(100, "причина", "проход"),
        episode_event(101, "причина", "проход"),
        episode_event(200, "причина", "проход"),
    ]);

    assert_eq!(journal.entries().len(), 3);
    assert_eq!(
        journal.entries().iter().map(|e| e.pid).collect::<Vec<_>>(),
        vec![100, 101, 200]
    );
}

/// Причина эпизода, ставшая известной, дописывается всем его записям: процессов
/// в эпизоде десятки, и причина у них общая. Fail-closed пишет «ещё не проверено»
/// раньше вердикта, а второго набора записей не будет — цели к тому моменту
/// уже мертвы.
#[test]
fn journal_refines_every_record_of_the_episode() {
    let mut journal = Journal::default();
    journal.append(vec![episode_event(1, "чужое", "другой")]);
    journal.append(vec![
        episode_event(7, "Подключение ещё не проверено", "наш"),
        episode_event(8, "Подключение ещё не проверено", "наш"),
    ]);

    assert!(journal.refine_episode(
        "наш",
        Some("Адрес 185.228.113.231 в чёрном списке"),
        None,
        None,
        None
    ));

    let ours: Vec<&str> = journal
        .entries()
        .iter()
        .filter(|e| e.episode_id == "наш")
        .map(|e| e.reason_text.as_str())
        .collect();
    assert_eq!(
        ours,
        vec![
            "Адрес 185.228.113.231 в чёрном списке",
            "Адрес 185.228.113.231 в чёрном списке"
        ]
    );
    assert_eq!(journal.entries()[0].reason_text, "чужое");
}

/// Эпизод, начавшийся до вердикта и закончившийся безопасным выходом, обязан
/// сказать, чем кончился: без этого в журнале навсегда остаётся отговорка,
/// и завершение выглядит беспричинным.
#[test]
fn journal_records_how_a_pending_episode_ended() {
    let mut journal = Journal::default();
    journal.append(vec![episode_event(7, "Подключение ещё не проверено", "наш")]);

    assert!(journal.refine_episode(
        "наш",
        None,
        Some("проверка завершилась безопасным выходом: 1.2.3.4, KZ"),
        None,
        None
    ));

    assert_eq!(
        journal.entries()[0].resolution_text.as_deref(),
        Some("проверка завершилась безопасным выходом: 1.2.3.4, KZ")
    );
    assert_eq!(
        journal.entries()[0].reason_text,
        "Подключение ещё не проверено",
        "причина не подменяется: она и была «пока не знаю»"
    );
}

#[test]
fn refining_an_unknown_episode_changes_nothing() {
    let mut journal = Journal::default();
    assert!(!journal.refine_episode("нет такого", Some("причина"), None, None, None));
    assert!(journal.entries().is_empty());
}

/// Журнал прежнего формата не выбрасывается: одна старая запись про N процессов
/// разворачивается в N записей одного эпизода.
#[test]
fn a_legacy_journal_expands_into_a_record_per_process() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("journal.json");
    std::fs::write(
        &path,
        r#"{"entries":[{"at":{"secs_since_epoch":1,"nanos_since_epoch":0},
           "targetNames":["claude"],"kind":"terminated",
           "reasonText":"Подключение ещё не проверено","ip":null,"country":null,
           "confirmedCountry":null,"confirmSource":null,
           "killedPids":[92594,92261,26200]}]}"#,
    )
    .unwrap();

    let journal = Journal::load(&path);

    assert_eq!(journal.entries().len(), 3);
    assert_eq!(
        journal.entries().iter().map(|e| e.pid).collect::<Vec<_>>(),
        vec![92594, 92261, 26200]
    );
    assert_eq!(journal.entries()[0].target_name, "claude");
    assert_eq!(
        journal.entries()[0].episode_id,
        journal.entries()[2].episode_id,
        "старая запись — один эпизод"
    );
}

#[test]
fn journal_survives_a_round_trip() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("state/journal.json");

    let mut journal = Journal::default();
    journal.append(vec![event(42, "VPN не поднят")]);
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
    nameless.target_name.clear();

    assert_eq!(nameless.title(), "неизвестная цель · pid 1");
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
        Err(GeoListEntryError::InvalidEntry)
    );
    assert_eq!(
        settings.add_blocked_entry("  "),
        Err(GeoListEntryError::Empty)
    );
    assert_eq!(
        settings.add_blocked_entry("RU"),
        Err(GeoListEntryError::Duplicate)
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

#[test]
fn allowed_entries_are_normalised_and_split_by_kind() {
    let mut settings = Settings::default();

    settings.add_allowed_entry(" nl ").unwrap();
    settings.add_allowed_entry("198.51.100.0/24").unwrap();

    assert_eq!(settings.allowed_countries, ["NL"]);
    assert_eq!(settings.allowed_ip_ranges, ["198.51.100.0/24"]);
    assert!(
        settings.blocked_entries().is_empty(),
        "белый список не должен течь в чёрный"
    );
}

#[test]
fn malformed_and_duplicate_allowed_entries_are_rejected() {
    let mut settings = Settings::default();
    settings.add_allowed_entry("NL").unwrap();

    assert_eq!(
        settings.add_allowed_entry("nl"),
        Err(GeoListEntryError::Duplicate)
    );
    assert_eq!(
        settings.add_allowed_entry("не адрес"),
        Err(GeoListEntryError::InvalidEntry)
    );
    assert_eq!(
        settings.add_allowed_entry("  "),
        Err(GeoListEntryError::Empty)
    );
    assert_eq!(settings.allowed_entries().len(), 1);
}

#[test]
fn removing_an_allowed_entry_clears_it_from_both_lists() {
    let mut settings = Settings::default();
    settings.add_allowed_entry("NL").unwrap();
    settings.add_allowed_entry("198.51.100.0/24").unwrap();

    settings.remove_entry("NL", GeoListKind::Allowed);
    settings.remove_entry("198.51.100.0/24", GeoListKind::Allowed);

    assert!(settings.allowed_entries().is_empty());
}

/// Одна и та же запись в обоих списках — допустимый ввод: приоритет задаёт
/// политика, а не поле ввода.
#[test]
fn the_same_entry_may_live_in_both_lists() {
    let mut settings = Settings::default();

    settings.add_blocked_entry("NL").unwrap();
    settings.add_allowed_entry("NL").unwrap();

    assert_eq!(settings.blocked_entries(), ["NL"]);
    assert_eq!(settings.allowed_entries(), ["NL"]);
}

/// Конфиг, записанный до появления whitelist, обязан читаться — с пустым
/// белым списком и целым чёрным.
#[test]
fn a_config_written_before_the_whitelist_still_loads() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("config.toml");
    std::fs::write(
        &path,
        r#"
is_enabled = true
blocked_countries = ["RU"]
blocked_ip_ranges = ["10.0.0.0/8"]
targets = []
theme = "dark"
revision = 4
"#,
    )
    .unwrap();

    let settings = Settings::load(&path).unwrap();

    assert_eq!(settings.blocked_countries, ["RU"]);
    assert!(settings.allowed_countries.is_empty());
    assert!(settings.allowed_ip_ranges.is_empty());
    assert!(!settings.guard_config().has_whitelist());
}

#[test]
fn the_guard_config_carries_the_whitelist() {
    let mut settings = Settings::default();
    settings.add_allowed_entry("NL").unwrap();
    settings.add_allowed_entry("198.51.100.0/24").unwrap();

    let config = settings.guard_config();

    assert!(config.allowed_countries.contains("NL"));
    assert_eq!(config.allowed_ip_ranges.len(), 1);
    assert!(config.allowed_ip_ranges[0].contains("198.51.100.7"));
}
