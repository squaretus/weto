//! Прогон контракта формата выгрузки из `shared/fixtures/journal-export.json`.
//!
//! Тот же файл читает `macos/Tests/WetoSharedTests/JournalExportFixtureTests.swift`.
//! Файл выгрузки читает не только человек, но и агент, которому его отдают
//! со словами «разберись, почему завершились цели»: разные имена полей у двух
//! платформ означали бы, что разбирать придётся дважды, и расхождение всплыло бы
//! у пользователя, а не в тестах.

use std::collections::BTreeSet;
use std::time::{Duration, UNIX_EPOCH};

use serde::Deserialize;
use serde_json::Value;

use weto_config::export::JournalExport;
use weto_config::journal::{
    GeoServiceTrace, KillDiagnostics, KillEvent, KillEventKind, VerdictStaleness, BODY_LIMIT,
};
use weto_config::settings::{Settings, Target};
use weto_core::process::TargetKind;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Contract {
    schema_version: u32,
    envelope_keys: Vec<String>,
    app_keys: Vec<String>,
    settings_keys: Vec<String>,
    event_keys: Vec<String>,
    diagnostics_keys: Vec<String>,
    staleness_keys: Vec<String>,
    trace_keys: Vec<String>,
    staleness_causes: Vec<String>,
    event_kinds: Vec<String>,
    timestamp_fields: Vec<String>,
    body_limit: usize,
    forbidden_substrings: Vec<String>,
}

/// Путь берётся от исходника теста: фикстуры лежат вне `linux/`, и копировать их
/// значило бы завести вторую копию.
fn contract() -> Contract {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../..")
        .join("shared/fixtures/journal-export.json");
    let text = std::fs::read_to_string(&root)
        .unwrap_or_else(|error| panic!("контракт не прочитался {root:?}: {error}"));
    serde_json::from_str(&text).expect("контракт испорчен")
}

/// Случай заполнен целиком: Swift опускает пустые поля, serde печатает их как
/// null, и на пустых полях списки ключей разъехались бы не по делу.
fn export() -> (Value, String) {
    let settings = Settings {
        is_enabled: true,
        vpn_app: Some(Target {
            entry: "org.happ.Happ".to_string(),
            display_name: "Happ".to_string(),
            kind: TargetKind::Binary,
            path: "/usr/bin/happ".to_string(),
            launch_paths: vec![],
        }),
        blocked_countries: vec!["RU".to_string()],
        blocked_ip_ranges: vec!["185.228.113.0/24".to_string()],
        allowed_countries: vec!["KZ".to_string()],
        allowed_ip_ranges: vec!["176.12.76.0/24".to_string()],
        targets: vec![Target {
            entry: "/home/square/.local/bin/claude".to_string(),
            display_name: "claude".to_string(),
            kind: TargetKind::Binary,
            path: "/home/square/.local/bin/claude".to_string(),
            launch_paths: vec![],
        }],
        ..Default::default()
    };

    let moment = UNIX_EPOCH + Duration::from_secs(1_787_000_000);
    let event = KillEvent {
        id: "эпизод-0".to_string(),
        episode_id: "эпизод".to_string(),
        at: moment,
        target_name: "claude".to_string(),
        pid: 92594,
        parent_pid: 1,
        executable_path: "/home/square/.local/bin/claude".to_string(),
        is_descendant: true,
        kind: KillEventKind::Terminated,
        reason_text: "Подключение ещё не проверено".to_string(),
        resolution_text: Some(
            "проверка завершилась безопасным выходом: 176.12.76.15, KZ".to_string(),
        ),
        ip: Some("176.12.76.15".to_string()),
        country: Some("KZ".to_string()),
        confirmed_country: Some("KZ".to_string()),
        confirm_source: Some("freeipapi".to_string()),
        diagnostics: Some(KillDiagnostics {
            staleness: Some(VerdictStaleness::new(
                Some(3),
                3,
                Some("out=wg0/10.2.0.2".to_string()),
                "out=wg0/10.2.0.5".to_string(),
            )),
            outgoing_interface: Some("wg0".to_string()),
            outgoing_address: Some("10.2.0.5".to_string()),
            has_network_path: Some(true),
            vpn_app_entry: Some("org.happ.Happ".to_string()),
            vpn_app_status: Some("Running".to_string()),
            services: vec![GeoServiceTrace {
                service: "ipinfo".to_string(),
                url: "https://v4.api.ipinfo.io/lite/me".to_string(),
                http_status: Some(200),
                duration_milliseconds: Some(42),
                body: Some(r#"{"ip":"176.12.76.15","country_code":"KZ"}"#.to_string()),
                failure: Some("нет".to_string()),
                from_cache: true,
                cache_age_seconds: Some(7),
            }],
            probed_at: Some(moment),
            app_version: Some("0.0.0".to_string()),
        }),
    };

    let export = JournalExport::build(
        &settings,
        vec![event],
        true,
        UNIX_EPOCH + Duration::from_secs(1_787_000_100),
        "Linux 6.8.0".to_string(),
    );
    let text = export.encoded().expect("выгрузка не собралась");
    (
        serde_json::from_str(&text).expect("выгрузка не разобралась"),
        text,
    )
}

fn keys(value: &Value) -> BTreeSet<String> {
    value
        .as_object()
        .expect("ожидался объект")
        .keys()
        .cloned()
        .collect()
}

fn expected(list: &[String]) -> BTreeSet<String> {
    list.iter().cloned().collect()
}

#[test]
fn envelope_matches_the_shared_contract() {
    let contract = contract();
    let (object, _) = export();

    assert_eq!(object["schemaVersion"], contract.schema_version);
    assert_eq!(keys(&object), expected(&contract.envelope_keys), "конверт");
    assert_eq!(keys(&object["app"]), expected(&contract.app_keys), "app");
    assert_eq!(
        keys(&object["settings"]),
        expected(&contract.settings_keys),
        "settings"
    );
}

#[test]
fn event_matches_the_shared_contract() {
    let contract = contract();
    let (object, _) = export();
    let event = &object["events"][0];

    assert_eq!(keys(event), expected(&contract.event_keys), "событие");

    let diagnostics = &event["diagnostics"];
    assert_eq!(
        keys(diagnostics),
        expected(&contract.diagnostics_keys),
        "diagnostics"
    );
    assert_eq!(
        keys(&diagnostics["staleness"]),
        expected(&contract.staleness_keys),
        "staleness"
    );
    assert_eq!(
        keys(&diagnostics["services"][0]),
        expected(&contract.trace_keys),
        "трасса сервиса"
    );

    assert!(contract
        .event_kinds
        .contains(&event["kind"].as_str().unwrap().to_string()));
    assert!(contract.staleness_causes.contains(
        &diagnostics["staleness"]["cause"]
            .as_str()
            .unwrap()
            .to_string()
    ));
}

/// `SystemTime` по умолчанию сериализуется объектом, а не строкой: без этой
/// проверки формат отметок разъехался бы с macOS молча.
#[test]
fn timestamps_are_iso8601_in_utc() {
    let contract = contract();
    let (object, _) = export();
    let event = &object["events"][0];

    for field in &contract.timestamp_fields {
        let stamp = object
            .get(field)
            .or_else(|| event.get(field))
            .or_else(|| event["diagnostics"].get(field))
            .and_then(Value::as_str)
            .unwrap_or_else(|| panic!("поля {field} нет ни в конверте, ни в записи"));

        // Регулярных выражений в ядре нет и заводить их незачем: форма отметки
        // короткая и проверяется посимвольно.
        let bytes = stamp.as_bytes();
        assert_eq!(bytes.len(), 20, "отметка «{stamp}» в поле {field}");
        assert_eq!(bytes[4], b'-', "отметка «{stamp}»");
        assert_eq!(bytes[7], b'-', "отметка «{stamp}»");
        assert_eq!(bytes[10], b'T', "отметка «{stamp}»");
        assert_eq!(bytes[13], b':', "отметка «{stamp}»");
        assert_eq!(bytes[16], b':', "отметка «{stamp}»");
        assert_eq!(bytes[19], b'Z', "отметка «{stamp}»");
        assert!(
            bytes.iter().enumerate().all(|(index, byte)| {
                matches!(index, 4 | 7 | 10 | 13 | 16 | 19) || byte.is_ascii_digit()
            }),
            "отметка «{stamp}» в поле {field} не по ISO 8601"
        );
    }
}

/// Токен уходит заголовком, а заголовки в журнал не записываются вовсе.
#[test]
fn export_never_carries_the_token_or_its_header() {
    let contract = contract();
    let (_, text) = export();

    for forbidden in &contract.forbidden_substrings {
        assert!(
            !text.contains(forbidden),
            "в выгрузке нашлось «{forbidden}» — файл отдают в переписку"
        );
    }
}

#[test]
fn body_limit_is_the_shared_one() {
    assert_eq!(BODY_LIMIT, contract().body_limit);
}
