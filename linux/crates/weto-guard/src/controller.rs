//! Машина состояний охраны.
//!
//! # Свежесть вердикта
//!
//! Сетевой вердикт годен, пока не изменились две вещи: ревизия настроек
//! и отпечаток снимка сети. Без этого признака охрана обязана считать вердикт
//! отсутствующим — а отсутствие вердикта означает `VerificationPending`,
//! то есть завершение целей.
//!
//! Соблазн выбросить признак свежести и просто спрашивать сеть на каждом тике
//! разбивается о цифры: тик идёт раз в пять секунд, и при исправном VPN цели
//! умирали бы каждые пять секунд, пока идёт запрос.
//!
//! # Порядок
//!
//! Сначала локальное основание — падение туннеля видно из ядра мгновенно.
//! В сеть идём только тогда, когда локально придраться не к чему.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use weto_config::settings::Settings;
use weto_core::geo::{GeoOutcome, GeoProbeReport};
use weto_core::policy::{decide, decide_local, pending_verification, GuardDecision, GuardSignals};
use weto_core::presentation::{status_presentation, GuardState, StatusPresentation};
use weto_core::process::RunningTarget;
use weto_sys::geo_probe::GeoProbing;
use weto_sys::network_snapshot::NetworkSnapshotReading;
use weto_sys::secret_store::SecretStoring;

use crate::enforcer::ProcessEnforcer;

/// Окно коалесценции: несколько событий сети подряд не должны порождать
/// несколько запросов. У подтверждающего сервиса лимит 60 запросов в минуту.
const COALESCE_WINDOW: Duration = Duration::from_millis(300);

/// Откуда пришёл запрос пробы. Кнопка ведёт себя иначе, чем таймер, и это
/// не оптимизация, а поведение продукта.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProbeTrigger {
    /// Штатный тик: в сеть идём только при нужде и с окном коалесценции.
    Scheduled,
    /// Кнопка «проверить»: спрашивает «где я сейчас», а не «нужна ли охране
    /// проверка». В сеть уходит всегда и без окна коалесценции.
    Manual,
}

pub trait SettingsProviding: Send + Sync {
    fn settings(&self) -> Settings;
}

pub trait KillReporting: Send + Sync {
    fn report(&self, killed: &[weto_core::process::MatchedProcess], reason: &str);
}

/// Вердикт вместе с признаком, при каких условиях он был получен.
#[derive(Debug, Clone)]
struct CachedVerdict {
    revision: u64,
    fingerprint: String,
    outcome: GeoOutcome,
    report: GeoProbeReport,
}

#[derive(Debug, Clone, Default)]
pub struct GuardSnapshot {
    pub decision: Option<GuardDecision>,
    pub presentation: Option<StatusPresentation>,
    pub report: Option<GeoProbeReport>,
    pub running: Vec<RunningTarget>,
    pub vpn_candidates: Vec<String>,
}

struct Inner {
    verdict: Option<CachedVerdict>,
    last_probe_finished: Option<Instant>,
    snapshot: GuardSnapshot,
}

pub struct GuardController {
    network: Box<dyn NetworkSnapshotReading>,
    geo: Box<dyn GeoProbing>,
    secrets: Box<dyn SecretStoring>,
    settings: Box<dyn SettingsProviding>,
    enforcer: ProcessEnforcer,
    reporter: Box<dyn KillReporting>,
    inner: Mutex<Inner>,
    probe_in_flight: Arc<AtomicBool>,
    coalesce_window: Duration,
}

impl GuardController {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        network: Box<dyn NetworkSnapshotReading>,
        geo: Box<dyn GeoProbing>,
        secrets: Box<dyn SecretStoring>,
        settings: Box<dyn SettingsProviding>,
        enforcer: ProcessEnforcer,
        reporter: Box<dyn KillReporting>,
    ) -> GuardController {
        GuardController {
            network,
            geo,
            secrets,
            settings,
            enforcer,
            reporter,
            inner: Mutex::new(Inner {
                verdict: None,
                last_probe_finished: None,
                snapshot: GuardSnapshot::default(),
            }),
            probe_in_flight: Arc::new(AtomicBool::new(false)),
            coalesce_window: COALESCE_WINDOW,
        }
    }

    /// Окно коалесценции задаётся снаружи только ради тестов: им нужно
    /// проверять и то, что окно работает, и то, что происходит за его пределами,
    /// не тратя на это по трети секунды на случай.
    pub fn with_coalesce_window(mut self, window: Duration) -> GuardController {
        self.coalesce_window = window;
        self
    }

    pub fn snapshot(&self) -> GuardSnapshot {
        self.inner
            .lock()
            .expect("состояние охраны")
            .snapshot
            .clone()
    }

    /// Штатный такт охраны.
    pub fn tick(&self) -> GuardDecision {
        self.run(ProbeTrigger::Scheduled)
    }

    /// Проверка по кнопке.
    ///
    /// Спрашивает «где я сейчас», а не «нужна ли охране проверка»: запрос
    /// уходит и тогда, когда судьба целей решена локально. Экономия запросов —
    /// свойство штатного тика; на кнопке она означала бы молчание экрана ровно
    /// в тот момент, когда пользователь хочет увидеть свою страну.
    ///
    /// Свежесть прежнего вердикта при этом не сбрасывается: иначе нажатие
    /// при исправном VPN роняло бы состояние в `VerificationPending`,
    /// то есть стоило бы пользователю целей.
    pub fn probe_now(&self) -> GuardDecision {
        self.run(ProbeTrigger::Manual)
    }

    fn run(&self, trigger: ProbeTrigger) -> GuardDecision {
        let settings = self.settings.settings();
        let network = self.network.snapshot();
        let config = settings.guard_config();
        let fingerprint = network.fingerprint();

        let vpn =
            weto_core::network::resolve_vpn_status(&network, settings.vpn_interface.as_deref());
        let local = decide_local(settings.is_enabled, vpn, &config);

        // Кнопка идёт в сеть даже при решённой локально судьбе целей,
        // но локальное основание применяется сразу, до ответа сети:
        // жизни целям кнопка не продлевает.
        if let Some(decision) = local.clone() {
            self.apply(&settings, decision.clone(), None);
            if trigger == ProbeTrigger::Manual {
                self.probe_and_store(&settings, &fingerprint);
                self.publish_report_only();
            }
            return decision;
        }

        if let Some(cached) = self.fresh_verdict(settings.revision, &fingerprint) {
            let decision = decide(&GuardSignals {
                is_enabled: settings.is_enabled,
                vpn,
                geo: cached.outcome.clone(),
                config,
            });
            self.apply(&settings, decision.clone(), Some(cached.report));
            return decision;
        }

        // Вердикта нет или он потерял свежесть: fail-closed до ответа сети.
        let pending = pending_verification(settings.is_enabled, &config);
        self.apply(&settings, pending.clone(), None);

        if trigger == ProbeTrigger::Manual || self.coalescing_window_passed() {
            if let Some(outcome) = self.probe_and_store(&settings, &fingerprint) {
                let decision = decide(&GuardSignals {
                    is_enabled: settings.is_enabled,
                    vpn,
                    geo: outcome,
                    config,
                });
                let report = self
                    .inner
                    .lock()
                    .expect("состояние охраны")
                    .verdict
                    .as_ref()
                    .map(|v| v.report.clone());
                self.apply(&settings, decision.clone(), report);
                return decision;
            }
        }

        pending
    }

    /// Вердикт годен, только если и настройки, и сеть те же самые.
    fn fresh_verdict(&self, revision: u64, fingerprint: &str) -> Option<CachedVerdict> {
        let inner = self.inner.lock().expect("состояние охраны");
        inner
            .verdict
            .clone()
            .filter(|v| v.revision == revision && v.fingerprint == fingerprint)
    }

    fn coalescing_window_passed(&self) -> bool {
        let inner = self.inner.lock().expect("состояние охраны");
        match inner.last_probe_finished {
            None => true,
            Some(at) => at.elapsed() >= self.coalesce_window,
        }
    }

    /// Запрос к сервисам. Повторное нажатие в полёте запроса второго не порождает.
    fn probe_and_store(&self, settings: &Settings, fingerprint: &str) -> Option<GeoOutcome> {
        if self.probe_in_flight.swap(true, Ordering::SeqCst) {
            return None;
        }

        let token = self.secrets.load().ok().flatten();
        let report = self.geo.probe(token.as_deref());
        let outcome = report.outcome();

        {
            let mut inner = self.inner.lock().expect("состояние охраны");
            inner.verdict = Some(CachedVerdict {
                revision: settings.revision,
                fingerprint: fingerprint.to_string(),
                outcome: outcome.clone(),
                report: report.clone(),
            });
            inner.last_probe_finished = Some(Instant::now());
            inner.snapshot.report = Some(report);
        }

        self.probe_in_flight.store(false, Ordering::SeqCst);
        Some(outcome)
    }

    fn publish_report_only(&self) {
        let mut inner = self.inner.lock().expect("состояние охраны");
        if let Some(verdict) = &inner.verdict {
            inner.snapshot.report = Some(verdict.report.clone());
        }
    }

    fn apply(&self, settings: &Settings, decision: GuardDecision, report: Option<GeoProbeReport>) {
        let rules = settings.target_rules();

        let running = match &decision {
            GuardDecision::Safe => self.enforcer.running(&rules),
            GuardDecision::Kill(reason) => {
                let result = self.enforcer.enforce(&rules);
                if !result.killed.is_empty() {
                    self.reporter.report(&result.killed, &reason.display_text());
                }
                result.running
            }
        };

        let country = report.as_ref().and_then(|r| match r.outcome() {
            GeoOutcome::Resolved(reading) => Some(reading.primary_country),
            GeoOutcome::Unavailable(_) => r.reference_country().map(str::to_string),
        });

        let presentation = status_presentation(&GuardState {
            is_enabled: settings.is_enabled,
            has_targets: !settings.targets.is_empty(),
            decision: decision.clone(),
            country,
        });

        let candidates = self
            .network
            .snapshot()
            .vpn_candidates()
            .iter()
            .map(|i| i.name.clone())
            .collect();

        let mut inner = self.inner.lock().expect("состояние охраны");
        inner.snapshot.decision = Some(decision);
        inner.snapshot.presentation = Some(presentation);
        inner.snapshot.running = running;
        inner.snapshot.vpn_candidates = candidates;
        if report.is_some() {
            inner.snapshot.report = report;
        }
    }
}
