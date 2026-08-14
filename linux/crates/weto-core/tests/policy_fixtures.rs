//! Прогон голден-фикстур политики из `shared/fixtures/guard-policy.json`.
//!
//! Тот же файл читает `macos/Tests/WetoCoreTests/GuardPolicyFixtureTests.swift`.
//! Это единственный механизм, которым расхождение двух реализаций ловится машинно:
//! без него порядок проверок или трактовка «нет подтверждения» разъедутся тихо,
//! и заметить это можно будет только по невыключенному kill-switch на одной из ОС.

use std::collections::HashSet;
use std::path::PathBuf;

use serde::Deserialize;
use weto_core::geo::{ConfirmSource, GeoOutcome, GeoReading};
use weto_core::ip::IpRange;
use weto_core::network::VpnStatus;
use weto_core::policy::{
    decide, decide_local, pending_verification, GuardConfig, GuardDecision, GuardSignals,
    UnsafeReason,
};

#[test]
fn every_fixture_case_matches_the_policy() {
    let suite = load_suite();
    assert!(
        !suite.cases.is_empty(),
        "фикстуры пусты — файл не найден или испорчен"
    );

    for fixture in &suite.cases {
        let actual = run(fixture);
        assert_eq!(
            actual,
            fixture.expect.as_decision(),
            "случай «{}»",
            fixture.name
        );
    }
}

/// `None` у `decide_local` — отдельный исход, а не отсутствие данных.
type Outcome = Option<GuardDecision>;

fn run(fixture: &Case) -> Outcome {
    let config = fixture.config.as_guard_config();

    match fixture.function.as_str() {
        "decide" => {
            let vpn = fixture
                .vpn
                .as_ref()
                .expect("decide требует vpn")
                .as_status();
            let geo = fixture
                .geo
                .as_ref()
                .expect("decide требует geo")
                .as_outcome();
            let signals = GuardSignals {
                is_enabled: fixture.is_enabled,
                vpn,
                geo,
                config,
            };
            Some(decide(&signals))
        }
        "decideLocal" => {
            let vpn = fixture
                .vpn
                .as_ref()
                .expect("decideLocal требует vpn")
                .as_status();
            decide_local(fixture.is_enabled, vpn, &config)
        }
        "pendingVerification" => Some(pending_verification(fixture.is_enabled, &config)),
        other => panic!("неизвестная функция «{other}» в случае «{}»", fixture.name),
    }
}

fn load_suite() -> Suite {
    // Путь берётся от корня крейта: фикстуры лежат вне linux/, и копировать их
    // внутрь значило бы завести вторую копию контракта.
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../shared/fixtures/guard-policy.json");
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("не прочитать {}: {e}", path.display()));
    serde_json::from_str(&text).expect("фикстуры не разбираются")
}

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    function: String,
    #[serde(rename = "isEnabled")]
    is_enabled: bool,
    vpn: Option<Vpn>,
    geo: Option<Geo>,
    config: Config,
    expect: Expect,
}

#[derive(Deserialize)]
struct Vpn {
    kind: String,
    #[serde(rename = "isPrimary")]
    is_primary: Option<bool>,
}

impl Vpn {
    fn as_status(&self) -> VpnStatus {
        match self.kind.as_str() {
            "down" => VpnStatus::Down,
            "up" => VpnStatus::Up {
                is_primary: self.is_primary.unwrap_or(false),
            },
            _ => VpnStatus::NotConfigured,
        }
    }
}

#[derive(Deserialize)]
struct Geo {
    kind: String,
    detail: Option<String>,
    ip: Option<String>,
    #[serde(rename = "primaryCountry")]
    primary_country: Option<String>,
    #[serde(rename = "confirmedCountry")]
    confirmed_country: Option<String>,
    #[serde(rename = "confirmSource")]
    confirm_source: Option<String>,
}

impl Geo {
    fn as_outcome(&self) -> GeoOutcome {
        if self.kind == "unavailable" {
            return GeoOutcome::Unavailable(self.detail.clone().unwrap_or_default());
        }
        GeoOutcome::Resolved(GeoReading {
            ip: self.ip.clone().expect("resolved без ip"),
            primary_country: self.primary_country.clone().expect("resolved без страны"),
            confirmed_country: self.confirmed_country.clone(),
            confirm_source: self
                .confirm_source
                .as_deref()
                .and_then(ConfirmSource::parse),
        })
    }
}

#[derive(Deserialize)]
struct Config {
    #[serde(rename = "vpnID")]
    vpn_id: Option<String>,
    #[serde(rename = "blockedCountries")]
    blocked_countries: Vec<String>,
    #[serde(rename = "blockedIPRanges")]
    blocked_ip_ranges: Vec<String>,
    targets: Vec<String>,
}

impl Config {
    fn as_guard_config(&self) -> GuardConfig {
        GuardConfig {
            vpn_id: self.vpn_id.clone(),
            blocked_countries: self
                .blocked_countries
                .iter()
                .cloned()
                .collect::<HashSet<_>>(),
            blocked_ip_ranges: self
                .blocked_ip_ranges
                .iter()
                .map(|text| {
                    IpRange::parse(text).unwrap_or_else(|| {
                        panic!("фикстуры содержат неразбираемый диапазон «{text}»")
                    })
                })
                .collect(),
            targets: self.targets.clone(),
        }
    }
}

#[derive(Deserialize)]
struct Expect {
    decision: String,
    reason: Option<Reason>,
}

impl Expect {
    fn as_decision(&self) -> Outcome {
        match self.decision.as_str() {
            "none" => None,
            "safe" => Some(GuardDecision::Safe),
            _ => Some(GuardDecision::Kill(
                self.reason.as_ref().expect("kill без причины").as_reason(),
            )),
        }
    }
}

#[derive(Deserialize)]
struct Reason {
    kind: String,
    detail: Option<String>,
    ip: Option<String>,
    code: Option<String>,
    source: Option<String>,
    primary: Option<String>,
    confirmed: Option<String>,
}

impl Reason {
    fn as_reason(&self) -> UnsafeReason {
        let text = |value: &Option<String>| value.clone().unwrap_or_default();
        match self.kind.as_str() {
            "verificationPending" => UnsafeReason::VerificationPending,
            "vpnNotConfigured" => UnsafeReason::VpnNotConfigured,
            "vpnDown" => UnsafeReason::VpnDown,
            "vpnNotPrimary" => UnsafeReason::VpnNotPrimary,
            "geoUnavailable" => UnsafeReason::GeoUnavailable(text(&self.detail)),
            "blacklistedIP" => UnsafeReason::BlacklistedIp(text(&self.ip)),
            "blockedCountry" => UnsafeReason::BlockedCountry {
                code: text(&self.code),
                source: text(&self.source),
            },
            "confirmationUnavailable" => UnsafeReason::ConfirmationUnavailable,
            "countryConflict" => UnsafeReason::CountryConflict {
                primary: text(&self.primary),
                confirmed: text(&self.confirmed),
            },
            other => panic!("неизвестная причина «{other}» в фикстурах"),
        }
    }
}
