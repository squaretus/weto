//! Прогон голден-фикстур политики показа из `shared/fixtures/update-policy.json`.
//!
//! Тот же файл читает `macos/Packages/UpdateKit/Tests/UpdateKitCoreTests/
//! UpdatePolicyFixtureTests.swift`. Правила пропуска и отсрочки оплачены опытом
//! и разъехаться между платформами не имеют права.

use std::path::PathBuf;
use std::time::{Duration, UNIX_EPOCH};

use serde::Deserialize;
use weto_update::policy::{decide, Outcome, UpdateDeferral, UpdateInfo};

#[test]
fn every_fixture_case_matches_the_policy() {
    let suite = load_suite();
    assert!(
        !suite.cases.is_empty(),
        "фикстуры пусты — файл не найден или испорчен"
    );

    let now = UNIX_EPOCH + Duration::from_secs(suite.now);

    for fixture in &suite.cases {
        let outcome = decide(&fixture.as_info(), &fixture.deferral.as_deferral(), now);
        assert_eq!(outcome, fixture.expected(), "случай «{}»", fixture.name);
    }
}

fn load_suite() -> Suite {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../shared/fixtures/update-policy.json");
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("не прочитать {}: {e}", path.display()));
    serde_json::from_str(&text).expect("фикстуры не разбираются")
}

#[derive(Deserialize)]
struct Suite {
    now: u64,
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    #[serde(rename = "latestVersion")]
    latest_version: String,
    #[serde(rename = "isNewer")]
    is_newer: bool,
    deferral: Deferral,
    outcome: String,
}

impl Case {
    fn as_info(&self) -> UpdateInfo {
        UpdateInfo {
            latest_version: self.latest_version.clone(),
            download_url: format!(
                "https://github.com/squaretus/weto/releases/download/v{}/weto.tar.zst",
                self.latest_version
            ),
            release_notes: None,
            is_newer: self.is_newer,
        }
    }

    fn expected(&self) -> Outcome {
        match self.outcome.as_str() {
            "prompt" => Outcome::Prompt,
            "install" => Outcome::Install,
            _ => Outcome::Silent,
        }
    }
}

#[derive(Deserialize)]
struct Deferral {
    #[serde(rename = "skippedVersion")]
    skipped_version: Option<String>,
    #[serde(rename = "remindAt")]
    remind_at: Option<u64>,
    #[serde(rename = "autoInstall")]
    auto_install: bool,
}

impl Deferral {
    fn as_deferral(&self) -> UpdateDeferral {
        UpdateDeferral {
            skipped_version: self.skipped_version.clone(),
            remind_at: self.remind_at.map(|s| UNIX_EPOCH + Duration::from_secs(s)),
            auto_install: self.auto_install,
        }
    }
}
