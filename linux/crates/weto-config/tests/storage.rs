//! Настройки, журнал и пути XDG.

use std::collections::HashSet;
use std::time::SystemTime;

use weto_config::journal::{
    episodes, visible_limit_caption, Journal, KillDiagnostics, KillEvent, KillEventKind,
    MatchBasis, EPISODE_CAPACITY, VISIBLE_LIMIT,
};
use weto_config::paths::Paths;
use weto_config::settings::{
    validate_tunnel_name, GeoListEntryError, GeoListKind, Settings, Target, TargetEntryError,
    TunnelNameError,
};
use weto_core::pause_ceiling::PauseCeiling;
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
        matched_by: MatchBasis::Rule,
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
fn the_pause_ceiling_defaults_to_one_minute_and_survives_a_restart() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("weto/config.toml");
    assert_eq!(Settings::default().pause_ceiling(), PauseCeiling::OneMinute);

    let settings = Settings {
        pause_ceiling_seconds: 300,
        ..Default::default()
    };
    settings.save(&path).unwrap();

    assert_eq!(
        Settings::load(&path).unwrap().pause_ceiling(),
        PauseCeiling::FiveMinutes
    );
}

/// Конфиг, написанный до появления выбора, открывается с прежней минутой,
/// а мусор в ключе — тоже с минутой, а не с ошибкой загрузки.
#[test]
fn an_old_or_odd_pause_ceiling_reads_as_one_minute() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("config.toml");

    std::fs::write(&path, "is_enabled = true\n").unwrap();
    assert_eq!(
        Settings::load(&path).unwrap().pause_ceiling(),
        PauseCeiling::OneMinute
    );

    // Значение не того типа — тоже минута, а не ошибка загрузки: упавший разбор
    // оставил бы охрану без целей, а следующая правка затёрла бы их умолчаниями.
    for odd in [
        "pause_ceiling_seconds = 42",
        "pause_ceiling_seconds = \"5 мин\"",
        "pause_ceiling_seconds = -1",
        "pause_ceiling_seconds = 300.5",
    ] {
        std::fs::write(
            &path,
            format!("{odd}\n[[targets]]\nentry = \"nano\"\ndisplay_name = \"nano\"\nkind = \"binary\"\npath = \"/usr/bin/nano\"\n"),
        )
        .unwrap();
        let settings = Settings::load(&path).unwrap_or_else(|e| panic!("{odd}: {e:?}"));
        assert_eq!(settings.pause_ceiling(), PauseCeiling::OneMinute, "{odd}");
        assert_eq!(settings.targets.len(), 1, "{odd}: цели не потеряны");
    }
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

/// Ёмкость считается эпизодами, а не процессами: свежие сверху, старейший
/// эпизод уходит целиком (`Constants.eventLogEpisodeCapacity` на macOS).
#[test]
fn journal_keeps_the_last_fifty_episodes() {
    assert_eq!(EPISODE_CAPACITY, 50);

    let mut journal = Journal::default();
    for pid in 0..(EPISODE_CAPACITY as i32 + 5) {
        journal.append(vec![episode_event(
            pid,
            "VPN не поднят",
            &format!("e{pid}"),
        )]);
    }

    assert_eq!(journal.entries().len(), EPISODE_CAPACITY);
    assert_eq!(
        journal.entries()[0].pid,
        EPISODE_CAPACITY as i32 + 4,
        "свежие сверху"
    );
    assert_eq!(journal.entries()[EPISODE_CAPACITY - 1].pid, 5);
}

/// Эпизод никогда не режется. При ёмкости в сто записей одна пауза на ~170
/// процессах вытесняла всю историю и сама оставалась в файле обрезком:
/// по журналу нельзя было сказать, что встало и сколько.
#[test]
fn a_large_episode_is_kept_whole_and_old_ones_leave_whole() {
    let mut journal = Journal::default();
    journal.append(
        (0..3)
            .map(|pid| episode_event(pid, "старый", "старейший"))
            .collect(),
    );
    for n in 1..EPISODE_CAPACITY {
        journal.append(vec![episode_event(n as i32, "r", &format!("e{n}"))]);
    }
    journal.append(
        (0..170)
            .map(|n| episode_event(1_000 + n, "пауза", "большой"))
            .collect(),
    );

    let entries = journal.entries();
    assert_eq!(
        entries.iter().filter(|e| e.episode_id == "большой").count(),
        170,
        "эпизод целиком"
    );
    assert!(
        entries.iter().all(|e| e.episode_id != "старейший"),
        "старейший ушёл целиком"
    );
    assert_eq!(episodes(entries).len(), EPISODE_CAPACITY);
}

/// Процесс, вставший под уже идущей паузой, дописывается в её эпизод позже.
/// Это не новый эпизод: места в журнале он не занимает.
#[test]
fn a_late_record_does_not_cost_an_episode() {
    let mut journal = Journal::default();
    journal.append(vec![episode_event(1, "пауза", "пауза")]);
    for n in 1..EPISODE_CAPACITY {
        journal.append(vec![episode_event(n as i32 + 10, "r", &format!("e{n}"))]);
    }
    journal.append(vec![episode_event(2, "пауза", "пауза")]);

    let pids: Vec<i32> = journal
        .entries()
        .iter()
        .filter(|e| e.episode_id == "пауза")
        .map(|e| e.pid)
        .collect();
    assert_eq!(pids, [2, 1]);
    assert!(
        journal.entries().iter().any(|e| e.episode_id == "e1"),
        "никто не вытеснен"
    );
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
        Some("Адрес 203.0.113.231 в чёрном списке"),
        None,
        None,
        None,
        &HashSet::new()
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
            "Адрес 203.0.113.231 в чёрном списке",
            "Адрес 203.0.113.231 в чёрном списке"
        ]
    );
    // Ищем по эпизоду, а не по индексу: порядок записей — свежие сверху,
    // и привязка к позиции ломается на первом же изменении порядка.
    let other = journal
        .entries()
        .iter()
        .find(|event| event.episode_id == "другой")
        .expect("чужая запись на месте");
    assert_eq!(other.reason_text, "чужое");
}

/// Эпизод, начавшийся до вердикта и закончившийся безопасным выходом, обязан
/// сказать, чем кончился: без этого в журнале навсегда остаётся отговорка,
/// и завершение выглядит беспричинным.
#[test]
fn journal_records_how_a_pending_episode_ended() {
    let mut journal = Journal::default();
    journal.append(vec![episode_event(
        7,
        "Подключение ещё не проверено",
        "наш",
    )]);

    assert!(journal.refine_episode(
        "наш",
        None,
        Some("проверка завершилась безопасным выходом: 1.2.3.4, KZ"),
        None,
        None,
        &HashSet::new()
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
    assert!(!journal.refine_episode(
        "нет такого",
        Some("причина"),
        None,
        None,
        None,
        &HashSet::new()
    ));
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

/// Шелл — третий способ попасть в журнал: под правило он не подходил, а SIGSTOP
/// получил. Формат общий с macOS, поэтому запись обязана читаться и здесь; старый
/// булев признак при этом читается по-прежнему.
#[test]
fn a_shell_record_round_trips_and_legacy_flag_still_reads() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("state/journal.json");

    let mut shell = event(100, "Подтверждающие сервисы недоступны");
    shell.matched_by = MatchBasis::Shell;
    shell.executable_path = "/bin/zsh".to_string();
    shell.kind = KillEventKind::Paused;
    let mut journal = Journal::default();
    journal.append(vec![shell]);
    journal.save(&path).unwrap();

    let loaded = Journal::load(&path);
    assert_eq!(loaded.entries()[0].matched_by, MatchBasis::Shell);
    assert_eq!(
        serde_json::to_value(MatchBasis::Shell).unwrap(),
        serde_json::json!("shell"),
        "имя в файле — часть общего с macOS формата"
    );

    let legacy = tmp.path().join("legacy.json");
    std::fs::write(
        &legacy,
        r#"{"entries":[{"id":"a","episodeID":"b","date":"1970-01-01T00:00:01Z",
           "targetName":"claude","pid":5,"parentPID":1,"executablePath":"/c",
           "isDescendant":true,"kind":"terminated","reasonText":"r"}]}"#,
    )
    .unwrap();
    assert_eq!(
        Journal::load(&legacy).entries()[0].matched_by,
        MatchBasis::Descendant,
        "журналы прежнего формата читаются по-прежнему"
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

/// Одно падение VPN на дереве claude — десятки записей, по одной на процесс.
/// В окне это одна строка: pid там не говорит ничего, а шесть одинаковых строк
/// подряд прятали всю остальную историю (`JournalEpisode` на macOS).
#[test]
fn records_of_one_pass_make_one_line() {
    let mut log: Vec<KillEvent> = (0..6)
        .map(|n| episode_event(56710 + n, "r", "первый"))
        .collect();
    log.push(episode_event(4000, "r", "второй"));

    let lines = episodes(&log);

    assert_eq!(
        lines.iter().map(|e| e.episode_id()).collect::<Vec<_>>(),
        ["первый", "второй"]
    );
    assert_eq!(
        lines.iter().map(|e| e.process_count()).collect::<Vec<_>>(),
        [6, 1]
    );
}

/// Процесс, вставший под уже идущей паузой, пишется тем же эпизодом позже —
/// поверх записей других эпизодов. Строка от этого не раздваивается, а время
/// у неё — когда цели встали.
#[test]
fn a_late_record_joins_its_episode_instead_of_opening_a_line() {
    let at = |seconds| SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(seconds);
    let mut late = episode_event(3, "r", "первый");
    late.at = at(30);
    let mut other = episode_event(2, "r", "второй");
    other.at = at(20);
    let mut opening = episode_event(1, "r", "первый");
    opening.at = at(10);
    let log = [late, other, opening];

    let lines = episodes(&log);

    assert_eq!(
        lines.iter().map(|e| e.episode_id()).collect::<Vec<_>>(),
        ["первый", "второй"]
    );
    assert_eq!(lines[0].process_count(), 2);
    assert_eq!(lines[0].at(), at(10));
}

/// Заголовок — цели, а не процессы: каждая один раз, в порядке, в каком
/// эпизод их задел.
#[test]
fn the_title_names_each_target_once() {
    let mut codex = event(3, "r");
    codex.target_name = "codex".to_string();
    let log = [codex, event(2, "r"), event(1, "r")];
    assert_eq!(episodes(&log)[0].title(), "nano, codex");

    let mut nameless = event(1, "r");
    nameless.target_name.clear();
    assert_eq!(episodes(&[nameless])[0].title(), "неизвестная цель");
}

/// У шелла свой исход — «продолжен: цель завершена …», — а строка рассказывает
/// про цели. Исход шелла показывается только тогда, когда других нет; без
/// исхода строки нет вовсе.
#[test]
fn the_outcome_is_the_targets_one_and_said_once() {
    let resolved = |pid, basis, text: &str| {
        let mut e = event(pid, "r");
        e.matched_by = basis;
        e.resolution_text = Some(text.to_string());
        e
    };

    let log = [
        resolved(3, MatchBasis::Shell, "продолжен: цель завершена по потолку"),
        resolved(2, MatchBasis::Descendant, "завершено по потолку"),
        resolved(1, MatchBasis::Rule, "завершено по потолку"),
    ];
    assert_eq!(
        episodes(&log)[0].resolution_line().as_deref(),
        Some("Итог: завершено по потолку")
    );

    let released = [
        resolved(2, MatchBasis::Rule, "продолжен: цель снята с охраны"),
        resolved(1, MatchBasis::Rule, "завершено по потолку"),
    ];
    assert_eq!(
        episodes(&released)[0].resolution_line().as_deref(),
        Some("Итог: завершено по потолку; продолжен: цель снята с охраны")
    );

    let only_shell = [resolved(1, MatchBasis::Shell, "продолжен")];
    assert_eq!(
        episodes(&only_shell)[0].resolution_line().as_deref(),
        Some("Итог: продолжен")
    );

    assert_eq!(episodes(&[event(1, "r")])[0].resolution_line(), None);
}

/// Строка показаний — дословно `JournalEpisode.diagnosticsText` на macOS: время
/// первым, адрес всегда, даже неизвестный, затем страны и число процессов, если
/// их больше одного. Ни pid, ни «потомок N».
#[test]
fn diagnostics_name_the_exit_and_how_many_processes_stood() {
    assert_eq!(
        episodes(&[event(1, "VPN не поднят")])[0].diagnostics_text("06.10.2026 14:03:09"),
        "06.10.2026 14:03:09 · IP: неизвестен"
    );

    let with_exit = |pid, basis| {
        let mut e = event(pid, "Страна ipinfo заблокирована");
        e.ip = Some("203.0.113.7".to_string());
        e.country = Some("KZ".to_string());
        e.confirmed_country = Some("KZ".to_string());
        e.confirm_source = Some("geojs".to_string());
        e.matched_by = basis;
        e
    };
    let log = [
        with_exit(2, MatchBasis::Descendant),
        with_exit(1, MatchBasis::Rule),
    ];
    assert_eq!(
        episodes(&log)[0].diagnostics_text("t"),
        "t · IP: 203.0.113.7 · ipinfo: KZ · geojs: KZ · процессов: 2"
    );

    let mut unnamed = event(1, "Расхождение стран");
    unnamed.confirmed_country = Some("RU".to_string());
    assert_eq!(
        episodes(&[unnamed])[0].diagnostics_text("t"),
        "t · IP: неизвестен · подтверждение: RU",
        "подтверждённая страна без названного сервиса не пропадает"
    );
}

/// Пауза по молчанию сервисов несёт адрес и страны прошлого вердикта — других
/// нет. Строка «IP … · ipinfo: KZ · geojs: KZ» под причиной «таймаут запроса»
/// читалась как «всё ответило KZ, а цели почему-то встали». Прошлый вердикт
/// назван прошлым — дословно как на macOS.
#[test]
fn an_established_verdict_is_not_passed_off_as_this_probes_answer() {
    let mut silent = event(1, "Не удалось определить внешний адрес: таймаут запроса");
    silent.ip = Some("176.12.76.15".to_string());
    silent.country = Some("KZ".to_string());
    silent.confirmed_country = Some("KZ".to_string());
    silent.confirm_source = Some("freeipapi".to_string());
    silent.diagnostics = Some(KillDiagnostics {
        verdict_origin: Some("established".to_string()),
        ..KillDiagnostics::default()
    });

    assert_eq!(
        episodes(&[silent])[0].diagnostics_text("t"),
        "t · последний подтверждённый выход: 176.12.76.15, KZ"
    );
}

#[test]
fn the_summary_is_the_kind_and_the_reason() {
    assert_eq!(
        episodes(&[event(1, "VPN не поднят")])[0].summary_text(),
        "завершено — VPN не поднят"
    );
}

/// На экране — последние двадцать, остальное честно отсылает к выгрузке
/// (`JournalCard.visibleLimit` на macOS).
#[test]
fn the_card_says_how_many_records_it_leaves_to_the_export() {
    assert_eq!(VISIBLE_LIMIT, 20);
    assert_eq!(visible_limit_caption(0), None);
    assert_eq!(visible_limit_caption(20), None);
    assert_eq!(
        visible_limit_caption(21).as_deref(),
        Some("Показаны последние 20 из 21 — выгрузите журнал целиком")
    );
    assert_eq!(
        visible_limit_caption(EPISODE_CAPACITY).as_deref(),
        Some("Показаны последние 20 из 50 — выгрузите журнал целиком")
    );
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

/// Системное хранилище терминальной версии — фиксированные пути, не `$HOME`.
#[test]
fn system_paths_live_in_etc_and_var_lib() {
    let paths = Paths::system();

    assert_eq!(
        paths.settings_file(),
        std::path::Path::new("/etc/weto/config.toml")
    );
    assert_eq!(paths.token_file(), std::path::Path::new("/etc/weto/token"));
    assert_eq!(
        paths.journal_file(),
        std::path::Path::new("/var/lib/weto/journal.json")
    );
    assert_eq!(
        paths.status_file(),
        std::path::Path::new("/var/lib/weto/status.json")
    );
    assert_eq!(
        paths.run_lock_file(),
        std::path::Path::new("/var/lib/weto/run.lock")
    );
}

/// Разбор записи чёрного списка живёт в настройках, а не в окне: мусор
/// не должен молча попадать в файл и висеть там как «не разобран».
#[test]
fn a_blacklist_entry_is_parsed_before_it_is_stored() {
    let mut settings = Settings::default();

    assert!(settings.add_blocked_entry("ru").is_ok());
    assert!(settings.add_blocked_entry("203.0.113.231").is_ok());
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

fn happ() -> Target {
    Target {
        entry: "happ".to_string(),
        display_name: "happ".to_string(),
        kind: TargetKind::Binary,
        path: "/usr/bin/happ".to_string(),
        launch_paths: vec![],
    }
}

/// VPN задаётся одним способом: выбор туннеля снимает приложение, выбор
/// приложения снимает туннель. Политика, получившая оба, проверяла бы два
/// источника защиты вместо одного.
#[test]
fn choosing_a_tunnel_drops_the_app_and_back() {
    let mut settings = Settings::default();

    settings.set_vpn_app(Some(happ()));
    settings.set_vpn_tunnel(Some("wg0".to_string()));
    assert_eq!(settings.vpn_tunnel.as_deref(), Some("wg0"));
    assert!(settings.vpn_app.is_none(), "туннель снял приложение");

    settings.set_vpn_app(Some(happ()));
    assert!(settings.vpn_app.is_some());
    assert!(settings.vpn_tunnel.is_none(), "приложение сняло туннель");

    // Снять выбор — не значит выбрать другое: снятие туннеля приложение
    // не трогает, и наоборот.
    settings.set_vpn_tunnel(None);
    assert!(settings.vpn_app.is_some());
    settings.set_vpn_tunnel(Some("wg0".to_string()));
    settings.set_vpn_app(None);
    assert_eq!(settings.vpn_tunnel.as_deref(), Some("wg0"));
}

/// Туннель доходит до политики, а конфиг без ключа читается как «не выбран».
#[test]
fn the_tunnel_reaches_the_policy_and_old_configs_read_without_it() {
    let settings = Settings {
        vpn_tunnel: Some("wg0".to_string()),
        ..Settings::default()
    };
    assert_eq!(settings.guard_config().vpn_tunnel.as_deref(), Some("wg0"));

    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("config.toml");
    std::fs::write(&path, "is_enabled = true\ntargets = []\n").unwrap();
    assert_eq!(Settings::load(&path).unwrap().vpn_tunnel, None);

    settings.save(&path).unwrap();
    assert_eq!(
        Settings::load(&path).unwrap().vpn_tunnel.as_deref(),
        Some("wg0")
    );
}

#[test]
fn a_tunnel_name_is_what_the_kernel_can_name() {
    assert_eq!(validate_tunnel_name(" wg0 "), Ok("wg0".to_string()));
    assert_eq!(
        validate_tunnel_name("tun.vpn_1-a"),
        Ok("tun.vpn_1-a".to_string())
    );
    assert_eq!(
        validate_tunnel_name("123456789012345").map(|n| n.len()),
        Ok(15)
    );
    for bad in ["", "1234567890123456", "wg 0", "wg/0", "туннель"] {
        assert_eq!(
            validate_tunnel_name(bad),
            Err(TunnelNameError::Invalid),
            "«{bad}»"
        );
    }
}

/// Цель добавляется одним путём на окно и терминал; отказы — с текстом.
#[test]
fn adding_a_target_refuses_the_empty_the_duplicate_and_the_vpn_app() {
    let mut settings = Settings::default();
    settings.set_vpn_app(Some(happ()));
    let nano = Target {
        entry: "nano".to_string(),
        display_name: "nano".to_string(),
        kind: TargetKind::Binary,
        path: "/usr/bin/nano".to_string(),
        launch_paths: vec![],
    };

    assert_eq!(settings.add_target(nano.clone()), Ok(()));
    assert_eq!(
        settings.add_target(nano.clone()),
        Err(TargetEntryError::Duplicate)
    );
    assert_eq!(
        settings.add_target(Target {
            entry: " ".to_string(),
            ..nano
        }),
        Err(TargetEntryError::Empty)
    );
    assert_eq!(settings.add_target(happ()), Err(TargetEntryError::IsVpnApp));
    assert_eq!(settings.targets.len(), 1);
}

/// Терминальная версия живёт в своём каталоге целиком: окно её туннеля
/// не видит, учёт остановленных у двух установок раздельный.
#[test]
fn the_terminal_version_keeps_its_own_directories() {
    let paths = Paths::rooted_named("/дом".into(), "weto-cli");

    assert_eq!(
        paths.settings_file(),
        std::path::Path::new("/дом/.config/weto-cli/config.toml")
    );
    assert_eq!(
        paths.stopped_file(),
        std::path::Path::new("/дом/.local/state/weto-cli/stopped.json")
    );
    assert_eq!(
        paths.status_file(),
        std::path::Path::new("/дом/.local/state/weto-cli/status.json")
    );
    assert_eq!(
        paths.run_lock_file(),
        std::path::Path::new("/дом/.local/state/weto-cli/run.lock")
    );
    assert_eq!(
        paths.token_file(),
        std::path::Path::new("/дом/.config/weto-cli/token")
    );
    // Приложение — прежние пути, байт в байт.
    assert_eq!(
        Paths::rooted("/дом".into()).settings_file(),
        std::path::Path::new("/дом/.config/weto/config.toml")
    );
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

/// Тексты видов записи общие с macOS дословно: файл выгрузки читают на обеих
/// платформах, и «на паузе» обязано звучать одинаково.
#[test]
fn kind_texts_and_wire_names_match_macos() {
    assert_eq!(KillEventKind::Terminated.display_text(), "завершено");
    assert_eq!(
        KillEventKind::LaunchBlocked.display_text(),
        "запуск запрещён"
    );
    assert_eq!(KillEventKind::Paused.display_text(), "на паузе");
    assert_eq!(
        serde_json::to_value(KillEventKind::Paused).unwrap(),
        serde_json::json!("paused"),
        "имя в файле — часть общего формата"
    );
}

/// Эпизод паузы отличается от завершения только видом и исходом: запись читается
/// и пишется тем же путём, иначе выгрузка с macOS не разобралась бы на Linux.
#[test]
fn a_paused_record_round_trips_with_its_resolution() {
    let mut paused = event(500, "Подключение ещё не проверено: вердикта ещё не было");
    paused.kind = KillEventKind::Paused;
    paused.resolution_text =
        Some("завершено по потолку: Подтверждение не получено за 1 мин".to_string());

    let json = serde_json::to_string(&paused).unwrap();
    let back: KillEvent = serde_json::from_str(&json).unwrap();

    assert_eq!(back, paused);
    assert_eq!(back.kind, KillEventKind::Paused);
}

/// Цель завершена, а шелл её терминала — продолжен: под общим исходом эпизода
/// запись шелла лгала бы, он жив. Поэтому исход по основанию переписывается
/// вторым, более узким проходом и не трогает остальные записи.
#[test]
fn a_shell_record_can_carry_its_own_outcome() {
    let mut journal = Journal::default();
    let mut shell = episode_event(100, "Сервисы не ответили", "стояние");
    shell.kind = KillEventKind::Paused;
    shell.matched_by = MatchBasis::Shell;
    let mut target = episode_event(200, "Сервисы не ответили", "стояние");
    target.kind = KillEventKind::Paused;
    journal.append(vec![shell, target]);

    journal.refine_episode(
        "стояние",
        None,
        Some("завершено по доказательству: VPN-приложение не запущено"),
        None,
        None,
        &HashSet::new(),
    );
    assert!(journal.refine_basis(
        "стояние",
        MatchBasis::Shell,
        "продолжен: цель завершена по доказательству: VPN-приложение не запущено",
        &HashSet::new()
    ));

    let by_pid = |pid: i32| {
        journal
            .entries()
            .iter()
            .find(|event| event.pid == pid)
            .and_then(|event| event.resolution_text.clone())
            .unwrap()
    };
    assert_eq!(
        by_pid(100),
        "продолжен: цель завершена по доказательству: VPN-приложение не запущено"
    );
    assert_eq!(
        by_pid(200),
        "завершено по доказательству: VPN-приложение не запущено"
    );
}

/// Записей с таким основанием у эпизода нет — переписывать нечего.
#[test]
fn a_narrow_refinement_says_when_it_found_nothing() {
    let mut journal = Journal::default();
    journal.append(vec![episode_event(200, "Сервисы не ответили", "стояние")]);

    assert!(!journal.refine_basis("стояние", MatchBasis::Shell, "продолжен", &HashSet::new()));
}
