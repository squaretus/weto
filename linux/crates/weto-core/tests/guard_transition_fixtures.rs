//! Прогон голден-фикстур машины состояний из `shared/fixtures/guard-transitions.json`.
//!
//! Тот же файл читает `macos/Tests/WetoCoreTests/GuardMachineFixtureTests.swift`.
//! Политика уже пришпилена своей фикстурой, но политика отвечает про один момент;
//! расхождение двух реализаций живёт в переходах — в том, какая фаза стоит, когда
//! начинается пауза и как считается потолок. Без общего файла это разъехалось бы
//! тихо: обе стороны остались бы «зелёными».

use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::Deserialize;
use weto_core::diagnostics::StalenessCause;
use weto_core::geo::{ConfirmSource, GeoOutcome, GeoReading};
use weto_core::guard_machine::{GuardEffect, GuardInput, GuardMachine, GuardPhase};
use weto_core::policy::{GuardDecision, UnprovenReason, UnsafeEvidence};

/// Версия схемы, под которую написан раннер. Расхождение — отказ, а не молчаливый
/// пропуск: иначе новая версия фикстур прогонялась бы старыми правилами.
const SCHEMA_VERSION: u32 = 2;

#[test]
fn every_fixture_case_matches_the_machine() {
    let suite = load_suite();
    assert_eq!(
        suite.version, SCHEMA_VERSION,
        "версия фикстур разъехалась с раннером"
    );
    assert!(
        !suite.cases.is_empty(),
        "фикстуры пусты — файл не найден или испорчен"
    );

    let reading = suite.reading.as_reading();
    for fixture in &suite.cases {
        let mut machine = GuardMachine::new(
            fixture.start.as_start_phase(&fixture.name, &reading),
            Duration::from_secs_f64(fixture.ceiling_seconds),
        );
        for step in &fixture.steps {
            let effect = machine.apply(
                step.input.as_input(&fixture.name, &reading),
                moment(step.at),
            );
            assert_eq!(
                effect,
                step.effect.as_effect(&fixture.name),
                "«{}» @{}: эффект",
                fixture.name,
                step.at
            );
            assert!(
                step.phase.matches(machine.phase()),
                "«{}» @{}: фаза {:?}",
                fixture.name,
                step.at,
                machine.phase()
            );
        }
    }
}

/// Проверка самой проверки: раннер обязан валиться на расхождении, а не сверять
/// пустоту. Без этого «зелёный» прогон ничего не доказывал бы — ровно та беда,
/// ради которой голден-фикстура и заведена.
#[test]
fn the_runner_rejects_a_phase_that_differs() {
    let suite = load_suite();
    assert!(
        suite.cases.iter().all(|case| !case.steps.is_empty()),
        "случай без шагов не сверяет ничего"
    );

    let expected = Phase {
        kind: "paused".to_string(),
        cause: None,
        evidence: None,
        reason: Some(Reason {
            kind: "confirmationUnavailable".to_string(),
            detail: None,
            observed: None,
        }),
    };
    assert!(expected.matches(&GuardPhase::Paused {
        since: UNIX_EPOCH,
        reason: UnprovenReason::ConfirmationUnavailable,
    }));
    assert!(
        !expected.matches(&GuardPhase::Paused {
            since: UNIX_EPOCH,
            reason: UnprovenReason::GeoUnavailable("таймаут запроса".to_string()),
        }),
        "другая причина паузы — расхождение"
    );
    assert!(
        !expected.matches(&GuardPhase::Disabled),
        "другая фаза — расхождение"
    );
    assert_eq!(
        "pause".to_string().as_effect("самопроверка"),
        GuardEffect::Pause
    );
}

/// Момент шага — секунды от нуля. Отсчитываем от эпохи: машине важна только разница.
fn moment(at: f64) -> SystemTime {
    UNIX_EPOCH + Duration::from_secs_f64(at)
}

fn load_suite() -> Suite {
    // Путь берётся от корня крейта: фикстуры лежат вне linux/, и копировать их
    // внутрь значило бы завести вторую копию контракта.
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../shared/fixtures/guard-transitions.json");
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("не прочитать {}: {e}", path.display()));
    serde_json::from_str(&text).expect("фикстуры не разбираются")
}

#[derive(Deserialize)]
struct Suite {
    version: u32,
    reading: Reading,
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    #[serde(rename = "ceilingSeconds")]
    ceiling_seconds: f64,
    start: Phase,
    steps: Vec<Step>,
}

#[derive(Deserialize)]
struct Step {
    at: f64,
    input: Input,
    phase: Phase,
    effect: String,
}

#[derive(Deserialize)]
struct Reading {
    ip: String,
    #[serde(rename = "primaryCountry")]
    primary_country: String,
    #[serde(rename = "confirmedCountry")]
    confirmed_country: Option<String>,
    #[serde(rename = "confirmSource")]
    confirm_source: Option<String>,
}

impl Reading {
    fn as_reading(&self) -> GeoReading {
        GeoReading {
            ip: self.ip.clone(),
            primary_country: self.primary_country.clone(),
            confirmed_country: self.confirmed_country.clone(),
            confirm_source: self
                .confirm_source
                .as_deref()
                .and_then(ConfirmSource::parse),
        }
    }
}

/// Ожидаемая фаза: сверяются `kind`, а также `cause`, `reason` и `evidence.kind`.
/// Узел, не заданный вовсе, раннер прощает и сверяет один `kind` — но файл этой
/// поблажкой не пользуется нигде: нагрузка выписана у каждой ожидаемой фазы,
/// иначе проверка выродилась бы в сверку вида, и подменённая причина паузы
/// прошла бы мимо обоих раннеров сразу.
/// Полезная нагрузка заданного узла (`detail`, `observed`, `ip`, `code`, `source`,
/// `primary`, `confirmed`, `cause`) обязательна: молчаливое умолчание в пустую строку
/// означало бы, что раннер разойдётся с macOS на первом же случае с нагрузкой,
/// и оба останутся зелёными.
/// Момент постановки на паузу не сверяется — он вычисляется из `at` шага, и сверять
/// его значило бы сверять раннер с самим собой.
#[derive(Deserialize)]
struct Phase {
    kind: String,
    cause: Option<String>,
    evidence: Option<Evidence>,
    reason: Option<Reason>,
}

impl Phase {
    /// Стартовая фаза случая. `paused` стартовой не бывает: у неё есть момент
    /// постановки, а он в файле не задаётся — такие случаи начинаются с шага,
    /// который на паузу и ставит. У `verifying` момента нет вовсе (цели в ней
    /// работают, и считать от неё нечего), поэтому стартовой она быть может.
    fn as_start_phase(&self, case: &str, reading: &GeoReading) -> GuardPhase {
        match self.kind.as_str() {
            "disabled" => GuardPhase::Disabled,
            "verifying" => GuardPhase::Verifying {
                cause: self.parsed_cause(case),
            },
            "protected" => GuardPhase::Protected(reading.clone()),
            "interference" => GuardPhase::Interference {
                reading: reading.clone(),
                reason: self
                    .reason
                    .as_ref()
                    .unwrap_or_else(|| panic!("«{case}»: стартовая фаза interference без причины"))
                    .as_unproven(case),
            },
            "danger" => GuardPhase::Danger(
                self.evidence
                    .as_ref()
                    .unwrap_or_else(|| panic!("«{case}»: стартовая фаза danger без улики"))
                    .as_evidence(case),
            ),
            other => panic!("«{case}»: фаза «{other}» стартовой быть не может"),
        }
    }

    fn parsed_cause(&self, case: &str) -> StalenessCause {
        let raw = self
            .cause
            .as_deref()
            .unwrap_or_else(|| panic!("«{case}»: фаза verifying без причины"));
        parse_cause(case, raw)
    }

    fn matches(&self, actual: &GuardPhase) -> bool {
        match (self.kind.as_str(), actual) {
            ("disabled", GuardPhase::Disabled) => true,
            ("verifying", GuardPhase::Verifying { cause }) => match self.cause.as_deref() {
                None => true,
                Some(raw) => parse_cause("ожидаемая фаза", raw) == *cause,
            },
            ("protected", GuardPhase::Protected(_)) => true,
            ("interference", GuardPhase::Interference { reason, .. }) => match &self.reason {
                None => true,
                Some(expected) => expected.as_unproven("ожидаемая фаза") == *reason,
            },
            ("paused", GuardPhase::Paused { reason, .. }) => match &self.reason {
                None => true,
                Some(expected) => expected.as_unproven("ожидаемая фаза") == *reason,
            },
            ("danger", GuardPhase::Danger(evidence)) => match &self.evidence {
                None => true,
                Some(expected) => expected.as_evidence("ожидаемая фаза") == *evidence,
            },
            _ => false,
        }
    }
}

fn parse_cause(case: &str, raw: &str) -> StalenessCause {
    match raw {
        "coldStart" => StalenessCause::ColdStart,
        "configurationChanged" => StalenessCause::ConfigurationChanged,
        "networkChanged" => StalenessCause::NetworkChanged,
        "configurationAndNetworkChanged" => StalenessCause::ConfigurationAndNetworkChanged,
        other => panic!("«{case}»: неизвестная причина несвежести «{other}»"),
    }
}

#[derive(Deserialize)]
struct Input {
    kind: String,
    cause: Option<String>,
    decision: Option<Decision>,
    geo: Option<Geo>,
    evidence: Option<Evidence>,
}

impl Input {
    fn as_input(&self, case: &str, reading: &GeoReading) -> GuardInput {
        match self.kind.as_str() {
            "tick" => GuardInput::Tick,
            "disarmed" => GuardInput::Disarmed,
            "verdictLost" => GuardInput::VerdictLost(parse_cause(
                case,
                self.cause
                    .as_deref()
                    .unwrap_or_else(|| panic!("«{case}»: verdictLost без причины")),
            )),
            "evidence" => GuardInput::Evidence(
                self.evidence
                    .as_ref()
                    .unwrap_or_else(|| panic!("«{case}»: вход evidence без улики"))
                    .as_evidence(case),
            ),
            "verdict" => GuardInput::Verdict {
                decision: self
                    .decision
                    .as_ref()
                    .unwrap_or_else(|| panic!("«{case}»: вход verdict без решения"))
                    .as_decision(case),
                geo: self
                    .geo
                    .as_ref()
                    .unwrap_or_else(|| panic!("«{case}»: вход verdict без гео"))
                    .as_outcome(case, reading),
            },
            "reassessment" => GuardInput::Reassessment {
                decision: self
                    .decision
                    .as_ref()
                    .unwrap_or_else(|| panic!("«{case}»: вход reassessment без решения"))
                    .as_decision(case),
                reading: reading.clone(),
            },
            other => panic!("«{case}»: неизвестный вход «{other}»"),
        }
    }
}

#[derive(Deserialize)]
struct Decision {
    kind: String,
    reason: Option<Reason>,
    evidence: Option<Evidence>,
}

impl Decision {
    fn as_decision(&self, case: &str) -> GuardDecision {
        match self.kind.as_str() {
            "safe" => GuardDecision::Safe,
            "unproven" => GuardDecision::Unproven(
                self.reason
                    .as_ref()
                    .unwrap_or_else(|| panic!("«{case}»: unproven без причины"))
                    .as_unproven(case),
            ),
            "kill" => GuardDecision::Kill(
                self.evidence
                    .as_ref()
                    .unwrap_or_else(|| panic!("«{case}»: kill без улики"))
                    .as_evidence(case),
            ),
            other => panic!("«{case}»: неизвестное решение «{other}»"),
        }
    }
}

#[derive(Deserialize)]
struct Geo {
    kind: String,
    detail: Option<String>,
    observed: Option<String>,
}

impl Geo {
    fn as_outcome(&self, case: &str, reading: &GeoReading) -> GeoOutcome {
        match self.kind.as_str() {
            "resolved" => GeoOutcome::Resolved(reading.clone()),
            "degraded" => GeoOutcome::Degraded {
                previous: reading.clone(),
                detail: self
                    .detail
                    .clone()
                    .unwrap_or_else(|| panic!("«{case}»: degraded без подробности")),
            },
            "unavailable" => GeoOutcome::Unavailable(
                self.detail
                    .clone()
                    .unwrap_or_else(|| panic!("«{case}»: unavailable без подробности")),
            ),
            "addressChanged" => GeoOutcome::AddressChanged {
                observed: self
                    .observed
                    .clone()
                    .unwrap_or_else(|| panic!("«{case}»: addressChanged без наблюдаемого адреса")),
                previous: reading.clone(),
            },
            other => panic!("«{case}»: неизвестное гео «{other}»"),
        }
    }
}

#[derive(Deserialize)]
struct Reason {
    kind: String,
    detail: Option<String>,
    observed: Option<String>,
}

impl Reason {
    fn as_unproven(&self, case: &str) -> UnprovenReason {
        match self.kind.as_str() {
            "geoUnavailable" => UnprovenReason::GeoUnavailable(
                self.detail
                    .clone()
                    .unwrap_or_else(|| panic!("«{case}»: geoUnavailable без подробности")),
            ),
            "addressChanged" => UnprovenReason::AddressChanged {
                observed: self
                    .observed
                    .clone()
                    .unwrap_or_else(|| panic!("«{case}»: addressChanged без наблюдаемого адреса")),
            },
            "confirmationUnavailable" => UnprovenReason::ConfirmationUnavailable,
            other => panic!("«{case}»: неизвестная unproven-причина «{other}»"),
        }
    }
}

#[derive(Deserialize)]
struct Evidence {
    kind: String,
    ip: Option<String>,
    code: Option<String>,
    source: Option<String>,
    primary: Option<String>,
    confirmed: Option<String>,
}

impl Evidence {
    fn as_evidence(&self, case: &str) -> UnsafeEvidence {
        match self.kind.as_str() {
            "vpnAppNotRunning" => UnsafeEvidence::VpnAppNotRunning,
            "blacklistedIP" => UnsafeEvidence::BlacklistedIp(
                self.ip
                    .clone()
                    .unwrap_or_else(|| panic!("«{case}»: blacklistedIP без адреса")),
            ),
            "blockedCountry" => UnsafeEvidence::BlockedCountry {
                code: self
                    .code
                    .clone()
                    .unwrap_or_else(|| panic!("«{case}»: blockedCountry без страны")),
                source: self
                    .source
                    .clone()
                    .unwrap_or_else(|| panic!("«{case}»: blockedCountry без источника")),
            },
            "countryConflict" => UnsafeEvidence::CountryConflict {
                primary: self
                    .primary
                    .clone()
                    .unwrap_or_else(|| panic!("«{case}»: countryConflict без основной страны")),
                confirmed: self.confirmed.clone().unwrap_or_else(|| {
                    panic!("«{case}»: countryConflict без подтверждённой страны")
                }),
            },
            "notWhitelistedIP" => UnsafeEvidence::NotWhitelistedIp(
                self.ip
                    .clone()
                    .unwrap_or_else(|| panic!("«{case}»: notWhitelistedIP без адреса")),
            ),
            "notWhitelistedCountry" => UnsafeEvidence::NotWhitelistedCountry(
                self.code
                    .clone()
                    .unwrap_or_else(|| panic!("«{case}»: notWhitelistedCountry без страны")),
            ),
            "pauseExpired" => UnsafeEvidence::PauseExpired,
            other => panic!("«{case}»: неизвестная улика «{other}»"),
        }
    }
}

trait AsEffect {
    fn as_effect(&self, case: &str) -> GuardEffect;
}

impl AsEffect for String {
    fn as_effect(&self, case: &str) -> GuardEffect {
        match self.as_str() {
            "none" => GuardEffect::None,
            "pause" => GuardEffect::Pause,
            "resume" => GuardEffect::Resume,
            "terminate" => GuardEffect::Terminate,
            other => panic!("«{case}»: неизвестный эффект «{other}»"),
        }
    }
}
