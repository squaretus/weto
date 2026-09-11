//! Машина состояний охраны: владелец редьюсера, сетевой пробы и свежести вердикта.
//!
//! Сам он не решает ничего — только готовит входы `GuardMachine` и выполняет
//! то, что редьюсер решил: пауза, продолжение, завершение. Порт
//! `macos/Sources/WetoShared/GuardController.swift` вместе с той частью
//! `GuardVM`, что применяет фазу к процессам и объясняет её журналом:
//! отдельного VM-слоя на Linux нет, а правила обязаны быть под тестами.
//!
//! # Три инварианта
//!
//! 1. **Пауза начинается с результата, а не с его ожидания.** Нет вердикта про
//!    текущий путь — объявляем потерю и просим пробу, а цели работают: решает
//!    ответ. Первый же ответ «не доказано» ставит на паузу; счёта неудачных проб
//!    нет, потолок паузы — завершение.
//! 2. **Устаревший результат не возвращает safe.** У каждой пробы своя ревизия
//!    и свой отпечаток: результат применяется, только пока оба актуальны.
//! 3. **Обязательство «вернуть из паузы» снимает наблюдение, а не отправка
//!    сигнала.** `kill(SIGCONT)` возвращает 0 и фоновому заданию, которое тут же
//!    получит SIGTTIN и встанет обратно.
//!
//! # Свежесть вердикта
//!
//! Сетевой вердикт годен, пока не изменились две вещи: ревизия настроек
//! и отпечаток снимка сети. Отпечаток берётся по выбранному интерфейсу, а не по
//! всей сети: иначе чужой VPN, переподключившийся сам по себе, стоил бы
//! пользователю целей. Потеря свежести целей больше не трогает — она просит пробу.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

use weto_config::settings::Settings;
use weto_core::check::{CheckEvent, CheckOutcome, CheckTrigger};
use weto_core::diagnostics::{GeoReadingPatch, KillContext, KillDiagnostics, VerdictStaleness};
use weto_core::geo::{GeoOutcome, GeoProbeReport, GeoReading};
use weto_core::guard_machine::{
    GuardAction, GuardEffect, GuardInput, GuardMachine, GuardPhase, PAUSE_CEILING,
};
use weto_core::network::NetworkSnapshot;
use weto_core::network::VpnAppStatus;
use weto_core::pause_plan::{PausedProcess, RecoveredProcess};
use weto_core::policy::GuardSignals;
use weto_core::policy::{decide, decide_local, GuardDecision, UnsafeEvidence};
use weto_core::process::{MatchBasis, MatchedProcess, RunningTarget};
use weto_sys::geo_probe::GeoProbing;
use weto_sys::network_snapshot::NetworkSnapshotReading;
use weto_sys::secret_store::SecretStoring;

use crate::enforcer::{ProcessEnforcer, Scan};

/// Окно коалесценции: несколько событий сети подряд не должны порождать
/// несколько запросов. У подтверждающего сервиса лимит 60 запросов в минуту.
const COALESCE_WINDOW: Duration = Duration::from_millis(300);

/// Расписание обращений к гео-сервисам. Отдельно от штатного тика: опрос системы
/// бесплатный и частый, запрос к чужим сервисам платный и редкий. Нужен потому, что
/// страна выхода меняется и на неизменном пути — например, когда пользователь
/// переключает сервер внутри своего клиента, — и отпечаток об этом не скажет.
const GEO_PROBE_INTERVAL: Duration = Duration::from_secs(5);

/// Сколько раз цели, ответившей стопом на собственный SIGCONT, досылается сигнал.
/// Дальше это не попытка возобновления, а `suspended (tty input)` в терминале
/// пользователя раз в секунду. Обязательство при этом остаётся: запись не уходит
/// из учёта, её исполнят завершение и штатный выход. Число то же, что у macOS
/// (`Constants.resumeRetryLimit`).
const RESUME_RETRY_LIMIT: u32 = 3;

/// Причина эпизода восстановления. Пробы за этим стоянием нет — и текст обязан
/// говорить это прямо, а не притворяться вердиктом. Дословно как на macOS.
pub const RECOVERY_REASON_TEXT: &str =
    "Найдены остановленными от прошлого запуска weto: пробы за этим стоянием нет";

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

/// Куда уходит запись о каждой попытке проверки — включая ту, где запрос
/// так и не ушёл. Журнал завершений про это молчит: проверка, не породившая
/// завершения, следа не оставляет.
pub trait CheckReporting: Send + Sync {
    fn record(&self, event: CheckEvent);
}

/// Куда уходит всё, что охрана сделала с процессами.
///
/// Объяснён обязан быть каждый посланный сигнал, а не только SIGKILL: цель,
/// шелл её терминала и процесс, найденный стоящим на старте, получают записи
/// одного вида (`kind: paused`) и один исход на эпизод.
pub trait KillReporting: Send + Sync {
    /// Завершённые процессы этого прохода.
    ///
    /// Списка два, потому что вопроса два. `killed` — все, кого проход
    /// действительно завершил: про них уведомление, и новость «цели завершены»
    /// не исчезает оттого, что цель перед смертью стояла. `recordable` — те,
    /// про кого записи ещё нет: pid, уже описанный эпизодом паузы, второй записи
    /// не заводит.
    fn report(
        &self,
        killed: &[MatchedProcess],
        recordable: &[MatchedProcess],
        context: &KillContext,
    );

    /// Цели снова работают: приёмник обнуляет здесь учёт «что уже описано».
    fn episode_finished(&self, _context: &KillContext) {}

    /// Процессы, которым этот проход послал SIGSTOP: цели, потомки и шеллы,
    /// вошедшие в план ради терминала цели. Один эпизод на всё стояние —
    /// повторных записей про те же pid не бывает.
    fn paused(&self, _stopped: &[MatchedProcess], _context: &KillContext) {}

    /// Терминальная цель под паузой потеряла терминал: её задание перестало
    /// быть передним, и `fg` в обычном терминале её больше не поднимет.
    /// Порт macOS `GuardNotifying.notifyBackgrounded`.
    fn backgrounded(&self, _target_name: &str) {}

    /// Процессы, застигнутые стоящими на старте: пробы за их стоянием нет,
    /// поэтому эпизод у них свой. Дата записи — когда процесс встал, а не когда
    /// weto это заметил.
    fn recovered(&self, _standing: &[RecoveredProcess], _context: &KillContext) {}

    /// Чем стояние кончилось: возобновлено, завершено по доказательству,
    /// завершено по потолку, остановлена охрана.
    ///
    /// `shell_outcome` — исход для записей с основанием `shell`, когда он
    /// расходится с исходом цели: шелла завершение возвращает SIGCONT, а не
    /// убивает, и под общим «завершено» его запись лгала бы.
    fn pause_resolved(&self, _outcome: &str, _shell_outcome: Option<&str>, _context: &KillContext) {
    }
}

/// Ревизия настроек и отпечаток выхода, при которых ответ уже получен.
type ProbedConditions = (u64, String);

/// Часы охраны. Подменяются только тестами — потолок паузы иначе проверялся бы
/// минутой ожидания на случай. Ход времени между пробами при этом меряет
/// `Instant`: расписание и окно коалесценции про стенные часы не спрашивают.
type Clock = Box<dyn Fn() -> SystemTime + Send + Sync>;

#[derive(Debug, Clone, Default)]
pub struct GuardSnapshot {
    /// Фаза охраны — то, что редьюсер решил про выход и про цели. Экран строит
    /// заголовок, цвет щита и три строки объяснения из неё через
    /// `weto_core::presentation`.
    pub phase: GuardPhase,
    pub report: Option<GeoProbeReport>,
    pub running: Vec<RunningTarget>,
    /// Цели, стоящие прямо сейчас: пилюли с отсчётом рисует порт интерфейса.
    pub paused: Vec<PausedProcess>,
    /// Когда истекает потолок паузы. `None` — цели не стоят.
    pub pause_deadline: Option<SystemTime>,
}

/// Учёт стояния: что уже описано журналом и кому сколько раз досылали SIGCONT.
#[derive(Default)]
struct PauseBook {
    /// Эпизод паузы открыт: его записи ждут исхода.
    episode_open: bool,
    /// Эпизод восстановления открыт: то же самое для стоящих с прошлого запуска.
    recovery_open: bool,
    /// pid, про которые эпизод уже рассказал.
    episode_pids: HashSet<i32>,
    /// Причина берётся у эпизода, а не у фазы: новорождённый под паузой обязан
    /// встать в один ряд с остальными, а не принести свой текст.
    episode_reason: Option<String>,
    /// Разбор свежести эпизода: чем прежний вердикт перестал описывать наш выход
    /// в тот момент, когда цели встали.
    staleness: Option<VerdictStaleness>,
    /// Кому SIGCONT уже уходил: только про них можно сказать, что сигнал
    /// не прижился.
    signalled_for_resume: HashSet<i32>,
    /// Сколько раз запись ответила стопом на собственный SIGCONT.
    stop_answers: HashMap<i32, u32>,
    /// Стоящие цели для экрана.
    paused: Vec<PausedProcess>,
}

struct Inner {
    machine: GuardMachine,
    /// Про какой путь и при каких настройках ответ уже получен — любой, включая
    /// отказ сервисов. Отказ тоже вердикт про этот путь: без него такт просил бы
    /// пробу заново каждые 300 мс, а решать всё равно нечем.
    verdict: Option<ProbedConditions>,
    /// Чтение, на котором стоит последний **состоявшийся** вердикт, вместе
    /// с отпечатком и ревизией того момента. Нужно трижды: чтобы молчание ipinfo
    /// не ставило цели на паузу при доказанно том же адресе; чтобы вернувшееся
    /// VPN-приложение переоценивалось без пробы; и чтобы разбор свежести знал,
    /// чем прежний вердикт перестал описывать наш выход. Отказ сервисов его
    /// не трогает — иначе изменение настроек стало бы неотличимо от холодного
    /// старта, а в журнале это два разных ответа на «почему цели встали».
    established: Option<Established>,
    /// Потеря вердикта, про которую показания на экране уже погашены. Гасить
    /// второй раз нельзя: такт идёт раз в секунду и затирал бы свежий отчёт.
    announced_loss: Option<(String, String)>,
    /// Разбор свежести на время применения плохого результата: он взводится
    /// перед вердиктом и гаснет сразу после, чтобы достаться ровно тому эпизоду,
    /// который этот результат и завёл.
    pending_staleness: Option<VerdictStaleness>,
    last_probe_finished: Option<Instant>,
    last_report: Option<GeoProbeReport>,
    last_reading: Option<GeoReading>,
    last_network: NetworkSnapshot,
    pause: PauseBook,
    snapshot: GuardSnapshot,
}

struct Established {
    reading: GeoReading,
    fingerprint: String,
    /// Ревизия настроек в момент, когда вердикт установился, — единственный способ
    /// сказать позже, изменились ли настройки со времени этого вердикта.
    revision: u64,
}

pub struct GuardController {
    network: Box<dyn NetworkSnapshotReading>,
    geo: Box<dyn GeoProbing>,
    secrets: Box<dyn SecretStoring>,
    settings: Box<dyn SettingsProviding>,
    enforcer: ProcessEnforcer,
    reporter: Box<dyn KillReporting>,
    checks: Box<dyn CheckReporting>,
    inner: Mutex<Inner>,
    probe_in_flight: Arc<AtomicBool>,
    coalesce_window: Duration,
    now: Clock,
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
        checks: Box<dyn CheckReporting>,
    ) -> GuardController {
        GuardController {
            network,
            geo,
            secrets,
            settings,
            enforcer,
            reporter,
            checks,
            inner: Mutex::new(Inner {
                machine: GuardMachine::default(),
                verdict: None,
                established: None,
                announced_loss: None,
                pending_staleness: None,
                last_probe_finished: None,
                last_report: None,
                last_reading: None,
                last_network: NetworkSnapshot::default(),
                pause: PauseBook::default(),
                snapshot: GuardSnapshot::default(),
            }),
            probe_in_flight: Arc::new(AtomicBool::new(false)),
            coalesce_window: COALESCE_WINDOW,
            now: Box::new(SystemTime::now),
        }
    }

    /// Окно коалесценции задаётся снаружи только ради тестов: им нужно
    /// проверять и то, что окно работает, и то, что происходит за его пределами,
    /// не тратя на это по трети секунды на случай.
    pub fn with_coalesce_window(mut self, window: Duration) -> GuardController {
        self.coalesce_window = window;
        self
    }

    /// Часы задаются снаружи только ради тестов: минута до потолка паузы
    /// проверяется переводом стрелок, а не минутой ожидания.
    pub fn with_clock(mut self, now: Clock) -> GuardController {
        self.now = now;
        self
    }

    pub fn snapshot(&self) -> GuardSnapshot {
        self.inner
            .lock()
            .expect("состояние охраны")
            .snapshot
            .clone()
    }

    pub fn phase(&self) -> GuardPhase {
        self.inner
            .lock()
            .expect("состояние охраны")
            .machine
            .phase()
            .clone()
    }

    /// Сколько цели ещё могут стоять. `None` — не стоят.
    pub fn remaining_pause(&self) -> Option<Duration> {
        self.inner
            .lock()
            .expect("состояние охраны")
            .machine
            .remaining_pause((self.now)())
    }

    /// Штатный такт охраны.
    pub fn tick(&self) -> GuardPhase {
        self.run(ProbeTrigger::Scheduled)
    }

    /// Проверка по кнопке.
    ///
    /// Спрашивает «где я сейчас», а не «нужна ли охране проверка»: запрос
    /// уходит и тогда, когда судьба целей решена локально. Экономия запросов —
    /// свойство штатного тика; на кнопке она означала бы молчание экрана ровно
    /// в тот момент, когда пользователь хочет увидеть свою страну.
    pub fn probe_now(&self) -> GuardPhase {
        self.run(ProbeTrigger::Manual)
    }

    // --- такт ---------------------------------------------------------------

    fn run(&self, trigger: ProbeTrigger) -> GuardPhase {
        let settings = self.settings.settings();
        let network = self.network.snapshot();
        let config = settings.guard_config();
        let fingerprint = network.verdict_fingerprint();
        self.inner.lock().expect("состояние охраны").last_network = network.clone();

        if !settings.is_enabled || !config.has_targets() {
            self.inner.lock().expect("состояние охраны").announced_loss = None;
            return self.dispatch(GuardInput::Disarmed, &settings);
        }

        let vpn = self.vpn_app_status(&settings);
        let has_verdict = self.has_verdict(settings.revision, &fingerprint);

        // Локальное доказательство применяется сразу, до сети: закрытый клиент —
        // завершение. Жизни целям сетевой запрос не продлевает.
        if let Some(GuardDecision::Kill(evidence)) = decide_local(settings.is_enabled, vpn, &config)
        {
            let phase = self.dispatch(GuardInput::Evidence(evidence), &settings);
            if !has_verdict {
                // Экран не должен показывать защиту, которой нет; проба нужна
                // ради показаний.
                self.forget_report();
            }
            if trigger == ProbeTrigger::Manual || (!has_verdict && self.coalescing_window_passed())
            {
                let reason = self.probe_trigger(trigger, settings.revision);
                self.probe_and_store(&settings, &fingerprint, reason);
            }
            return phase;
        }

        if !has_verdict {
            // Вердикта про этот путь нет: объявляем потерю и просим пробу — цели
            // при этом работают, паузу принесёт только плохой результат. Потолок
            // считает лишь `Tick`, поэтому он идёт тем же тактом: пауза, начатая
            // до смены пути, иначе не доехала бы до завершения.
            self.announce_loss(&settings, &fingerprint);
            if trigger == ProbeTrigger::Manual || self.coalescing_window_passed() {
                let reason = self.probe_trigger(trigger, settings.revision);
                if let Some(outcome) = self.probe_and_store(&settings, &fingerprint, reason) {
                    return self.apply_verdict(&settings, outcome, vpn, &fingerprint);
                }
            }
            return self.phase();
        }

        // Вердикт про этот путь есть — прошлая потеря закрыта.
        self.inner.lock().expect("состояние охраны").announced_loss = None;

        // VPN-приложение вернулось при действующем вердикте — переоценка без пробы.
        if let (GuardPhase::Danger(UnsafeEvidence::VpnAppNotRunning), Some(reading)) =
            (self.phase(), self.established_reading(&fingerprint))
        {
            let decision = decide(&GuardSignals {
                is_enabled: settings.is_enabled,
                vpn,
                geo: GeoOutcome::Resolved(reading.clone()),
                config: config.clone(),
            });
            self.dispatch(GuardInput::Reassessment { decision, reading }, &settings);
        }

        let phase = self.dispatch(GuardInput::Tick, &settings);

        // Расписание гео: страна выхода меняется и на неизменном пути. Пока цели
        // стоят, ритм тот же — проба и есть путь из паузы.
        if trigger == ProbeTrigger::Manual || self.geo_schedule_due() {
            let reason = if trigger == ProbeTrigger::Manual {
                CheckTrigger::Manual
            } else {
                CheckTrigger::Schedule
            };
            if let Some(outcome) = self.probe_and_store(&settings, &fingerprint, reason) {
                return self.apply_verdict(&settings, outcome, vpn, &fingerprint);
            }
        }
        phase
    }

    /// Объявление потери вердикта: цели не трогаем, потолок паузы считается тем же
    /// тактом, наружу уходит один эффект.
    ///
    /// Разбор свежести здесь не взводится: записи журнала эта потеря не заводит —
    /// заводит её плохой результат пробы, и разбор считается там, где применяется.
    fn announce_loss(&self, settings: &Settings, fingerprint: &str) {
        let staleness = self.staleness_now(settings.revision, fingerprint);
        let loss = (format!("{:?}", staleness.cause), fingerprint.to_string());
        let (should_forget, cause) = {
            let mut inner = self.inner.lock().expect("состояние охраны");
            let changed = inner.announced_loss.as_ref() != Some(&loss);
            let had_verdict = inner.established.is_some();
            inner.announced_loss = Some(loss);
            // `VerdictLost` во всех ветках возвращает `None` (см. `GuardMachine`),
            // поэтому эффект здесь не нужен: наружу уходит только `Tick`.
            inner
                .machine
                .apply(GuardInput::VerdictLost(staleness.cause), (self.now)());
            (changed && had_verdict, staleness.cause)
        };
        // Показания гасим один раз на потерю: они про путь, которого уже нет.
        if should_forget {
            self.forget_report();
        }
        let _ = cause;
        self.dispatch(GuardInput::Tick, settings);
    }

    /// Ответ пробы, пропущенный через политику.
    fn apply_verdict(
        &self,
        settings: &Settings,
        outcome: GeoOutcome,
        vpn: VpnAppStatus,
        fingerprint: &str,
    ) -> GuardPhase {
        let config = settings.guard_config();
        let decision = decide(&GuardSignals {
            is_enabled: settings.is_enabled,
            vpn,
            geo: outcome.clone(),
            config,
        });

        // Этот ответ откроет эпизод паузы — значит журналу нужен разбор свежести:
        // что было с выходом в момент, когда цели встали. Разбор есть только тогда,
        // когда прежний вердикт правда перестал описывать наш выход: молчание
        // сервисов при неизменном отпечатке свежести не теряет, и его отсутствие
        // там — ответ, а не пробел.
        if matches!(decision, GuardDecision::Unproven(_))
            && self.established_reading(fingerprint).is_none()
        {
            let staleness = self.staleness_now(settings.revision, fingerprint);
            self.inner
                .lock()
                .expect("состояние охраны")
                .pending_staleness = Some(staleness);
        }

        let phase = self.dispatch(
            GuardInput::Verdict {
                decision,
                geo: outcome,
            },
            settings,
        );
        self.inner
            .lock()
            .expect("состояние охраны")
            .pending_staleness = None;
        phase
    }

    // --- применение фазы ----------------------------------------------------

    /// Вход уезжает редьюсеру, его решение — процессам, а происшедшее — журналу.
    ///
    /// Обход процессов на всё применение один: и сигналы, и список живых целей,
    /// и наблюдение за учётом обязаны описывать один и тот же момент.
    fn dispatch(&self, input: GuardInput, settings: &Settings) -> GuardPhase {
        let moment = (self.now)();
        let (effect, phase) = {
            let mut inner = self.inner.lock().expect("состояние охраны");
            let effect = inner.machine.apply(input, moment);
            (effect, inner.machine.phase().clone())
        };

        let rules = settings.target_rules();
        let scan = self.enforcer.scan(&rules);

        match effect {
            // Снятие паузы разбирается ниже, в ветке работающих целей:
            // обязательство держится до наблюдения, и разбирает его каждый проход
            // с работающими целями, а не только тот, что принёс эффект.
            GuardEffect::Pause => self.pause_targets(&scan, settings, &phase),
            GuardEffect::Terminate => {
                if let GuardPhase::Danger(evidence) = &phase {
                    self.terminate_targets(&scan, settings, evidence);
                }
            }
            GuardEffect::None | GuardEffect::Resume => {}
        }

        if phase.action() == GuardAction::Run {
            // Цели снова работают — эпизод закрыт, и следующее завершение будет
            // первым, а не «запуском запрещён».
            let context = self.kill_context(settings, self.safe_outcome_text(&phase), None);
            self.reporter.episode_finished(&context);
            self.settle_resume(&scan, settings, &phase);
        }

        self.publish(&phase, &scan);
        phase
    }

    /// Причина эпизода паузы человеческим текстом: она же уходит в журнал.
    ///
    /// Стоящая фаза ровно одна, и приходит она с готовой причиной: «подключение
    /// ещё не проверено» больше не бывает причиной стояния — до ответа пробы цели
    /// работают.
    fn pause_reason_text(phase: &GuardPhase) -> String {
        match phase {
            GuardPhase::Paused { reason, .. } => reason.display_text(),
            other => other.title().to_string(),
        }
    }

    fn pause_targets(&self, scan: &Scan, settings: &Settings, phase: &GuardPhase) {
        let outcome = self.enforcer.pause(scan);

        // Пилюля с отсчётом описывает то, что стоит сейчас: цель, умершая под
        // паузой сама или снятая с охраны, оставалась бы в списке с живым
        // отсчётом и кнопкой, которой нечего показывать.
        let standing: HashSet<i32> = outcome.matched.iter().map(|m| m.pid).collect();

        // Про pid, уже описанный этим эпизодом, второй записи не бывает.
        // Шеллы идут тем же списком: объяснён обязан быть каждый SIGSTOP,
        // а не только посланный цели.
        let mut stopped: Vec<MatchedProcess> = outcome.fresh.clone();
        stopped.extend(outcome.fresh_shells.iter().cloned());

        let (newcomers, reason, staleness) = {
            let mut inner = self.inner.lock().expect("состояние охраны");
            inner.pause.paused.retain(|p| standing.contains(&p.pid));

            let newcomers: Vec<MatchedProcess> = stopped
                .into_iter()
                .filter(|process| !inner.pause.episode_pids.contains(&process.pid))
                .collect();
            if newcomers.is_empty() {
                return;
            }

            if !inner.pause.episode_open {
                inner.pause.episode_open = true;
                inner.pause.episode_reason = Some(Self::pause_reason_text(phase));
                inner.pause.staleness = inner.pending_staleness.clone();
                // Новое стояние — новое снятие паузы: pid, которым SIGCONT уходил
                // в прошлый раз, не имеют права сойти за «сигнал не прижился»
                // у этого эпизода, а счёт их ответов начинается заново.
                inner.pause.signalled_for_resume.clear();
                inner.pause.stop_answers.clear();
            }
            for process in &newcomers {
                inner.pause.episode_pids.insert(process.pid);
            }
            let reason = inner
                .pause
                .episode_reason
                .clone()
                .unwrap_or_else(|| Self::pause_reason_text(phase));
            let staleness = inner.pause.staleness.clone();
            (newcomers, reason, staleness)
        };

        let context = self.kill_context(settings, reason, staleness);
        self.reporter.paused(&newcomers, &context);

        let moment = (self.now)();
        let mut newly_backgrounded: Vec<String> = Vec::new();
        {
            let mut inner = self.inner.lock().expect("состояние охраны");
            for root in newcomers
                .iter()
                .filter(|p| p.matched_by == MatchBasis::Rule)
            {
                let backgrounded = outcome.plan.backgrounded.contains(&root.pid);
                // Признак «вернулось в фон» у дожившей пилюли вернее нашего: его
                // дописало наблюдение, а не догадка плана. А вот момент — наш: эта
                // цель успела поработать между эпизодами, значит стояние началось сейчас.
                if let Some(existing) = inner
                    .pause
                    .paused
                    .iter_mut()
                    .find(|paused| paused.pid == root.pid)
                {
                    existing.since = moment;
                    continue;
                }
                inner.pause.paused.push(PausedProcess {
                    pid: root.pid,
                    target_name: root.target_name.clone(),
                    since: moment,
                    is_backgrounded: backgrounded,
                });
                if backgrounded {
                    newly_backgrounded.push(root.target_name.clone());
                }
            }
        }
        for target_name in &newly_backgrounded {
            self.reporter.backgrounded(target_name);
        }
    }

    /// Снятие паузы: SIGCONT всем, кто ещё в учёте, и правда о том, что из этого
    /// вышло.
    ///
    /// Зовётся не эффектом `Resume`, а каждым проходом с работающими целями, пока
    /// учёт не пуст: обязательство снимает наблюдение, а не отправка сигнала.
    /// Цель, которую SIGCONT разбудил, а SIGTTIN тут же вернул в стоп, остаётся
    /// в учёте и получает сигнал снова — такт идёт раз в секунду, так что
    /// восстановление автоматическое и перезапуска приложения не требует.
    fn settle_resume(&self, scan: &Scan, settings: &Settings, phase: &GuardPhase) {
        if self.enforcer.ledger_is_empty() {
            return;
        }

        let (awaited, abandoned) = {
            let inner = self.inner.lock().expect("состояние охраны");
            let abandoned: HashSet<i32> = inner
                .pause
                .stop_answers
                .iter()
                .filter(|(_, answers)| **answers >= RESUME_RETRY_LIMIT)
                .map(|(pid, _)| *pid)
                .collect();
            (inner.pause.signalled_for_resume.clone(), abandoned)
        };

        let outcome = self.enforcer.resume(Some(scan), &abandoned);
        let refused: Vec<i32> = outcome
            .results
            .iter()
            .filter(|result| !result.is_delivered())
            .map(|result| result.pid)
            .collect();

        let answered: Vec<i32> = outcome
            .unresolved
            .iter()
            .map(|entry| entry.pid)
            .filter(|pid| awaited.contains(pid))
            .collect();

        {
            let mut inner = self.inner.lock().expect("состояние охраны");
            for result in &outcome.results {
                inner.pause.signalled_for_resume.insert(result.pid);
            }
            for pid in &outcome.released {
                inner.pause.stop_answers.remove(pid);
            }
            for pid in answered.iter().filter(|pid| !abandoned.contains(pid)) {
                *inner.pause.stop_answers.entry(*pid).or_insert(0) += 1;
            }
        }

        if outcome.is_complete() {
            self.resolve_pause_episode(settings, &self.resumed_episode_text(phase), None);
            let mut inner = self.inner.lock().expect("состояние охраны");
            inner.pause.signalled_for_resume.clear();
            inner.pause.stop_answers.clear();
            inner.pause.paused.clear();
            return;
        }

        // Цель, которая всё ещё стоит, возобновлённой выглядеть не имеет права:
        // пилюля остаётся, а признак «вернулась в фон» у неё теперь верен по факту —
        // терминал у шелла, иначе SIGCONT прижился бы.
        let standing: HashSet<i32> = outcome.unresolved.iter().map(|e| e.pid).collect();
        let mut newly_backgrounded: Vec<String> = Vec::new();
        {
            let mut inner = self.inner.lock().expect("состояние охраны");
            inner.pause.paused.retain(|p| standing.contains(&p.pid));
            for paused in inner.pause.paused.iter_mut() {
                if answered.contains(&paused.pid) && !paused.is_backgrounded {
                    paused.is_backgrounded = true;
                    newly_backgrounded.push(paused.target_name.clone());
                }
            }
        }
        for target_name in &newly_backgrounded {
            self.reporter.backgrounded(target_name);
        }

        if answered.is_empty() && refused.is_empty() {
            return;
        }
        let text = Self::unresolved_episode_text(&standing_pids(&outcome.unresolved), &refused);
        self.resolve_pause_episode(settings, &text, None);
    }

    /// Исход эпизода, у которого возобновление наблюдалось.
    fn resumed_episode_text(&self, phase: &GuardPhase) -> String {
        if matches!(phase, GuardPhase::Disabled) {
            return "возобновлено: охрана выключена или целей нет".to_string();
        }
        // Чтение самой фазы, а не последнее известное: паузу снимает конкретный
        // вердикт, и в исходе обязан стоять его адрес.
        let reading = phase.reading().cloned().or_else(|| {
            self.inner
                .lock()
                .expect("состояние охраны")
                .last_reading
                .clone()
        });
        match reading {
            Some(reading) => format!(
                "возобновлено: проверка подтвердила безопасный выход: {}, {}",
                reading.ip, reading.primary_country
            ),
            None => "возобновлено: проверка подтвердила безопасный выход".to_string(),
        }
    }

    /// Исход эпизода, у которого возобновления не случилось. Журнал обязан
    /// говорить правду: «возобновлено» пишется только про наблюдённое
    /// возобновление, иначе запись выдавала бы замороженную цель за живую.
    fn unresolved_episode_text(standing: &[i32], refused: &[i32]) -> String {
        if !refused.is_empty() {
            return format!(
                "не возобновлено: сигнал продолжения не дошёл до процессов {refused:?} — \
                 недостаточно прав"
            );
        }
        format!(
            "не возобновлено: процессы {standing:?} остались остановленными — \
             задание ушло в фон, продолжите его в терминале командой fg"
        )
    }

    /// Исход эпизода паузы: записи те же, к ним дописывается, чем стояние
    /// кончилось. Без исхода запись навсегда остаётся с отговоркой «сервисы
    /// не ответили», и пауза выглядит случайной.
    ///
    /// Эпизод восстановления закрывается тем же исходом и здесь же: стоящее
    /// с прошлой жизни и остановленное сейчас кончается одним и тем же.
    fn resolve_pause_episode(
        &self,
        settings: &Settings,
        outcome: &str,
        shell_outcome: Option<&str>,
    ) {
        let (open, reason, staleness) = {
            let mut inner = self.inner.lock().expect("состояние охраны");
            let open = inner.pause.episode_open || inner.pause.recovery_open;
            let reason = inner
                .pause
                .episode_reason
                .clone()
                .unwrap_or_else(|| RECOVERY_REASON_TEXT.to_string());
            let staleness = inner.pause.staleness.clone();
            if open {
                inner.pause.episode_open = false;
                inner.pause.recovery_open = false;
                inner.pause.episode_pids.clear();
                inner.pause.episode_reason = None;
                inner.pause.staleness = None;
            }
            (open, reason, staleness)
        };
        if !open {
            return;
        }
        let context = self.kill_context(settings, reason, staleness);
        self.reporter
            .pause_resolved(outcome, shell_outcome, &context);
    }

    fn terminate_targets(&self, scan: &Scan, settings: &Settings, evidence: &UnsafeEvidence) {
        let outcome = self.enforcer.terminate(scan);
        let reason = evidence.display_text();
        let cause = if *evidence == UnsafeEvidence::PauseExpired {
            "по потолку"
        } else {
            "по доказательству"
        };

        // Исход эпизода паузы: те же pid новых записей не заводят, поэтому список
        // снимается до того, как исход его обнулит.
        let skip: HashSet<i32> = self
            .inner
            .lock()
            .expect("состояние охраны")
            .pause
            .episode_pids
            .clone();
        // Шелл под доказательство не попадает: завершение возвращает ему SIGCONT,
        // а не SIGKILL, — «завершено» в его записи было бы неправдой.
        self.resolve_pause_episode(
            settings,
            &format!("завершено {cause}: {reason}"),
            Some(&format!("продолжен: цель завершена {cause}: {reason}")),
        );
        self.inner
            .lock()
            .expect("состояние охраны")
            .pause
            .paused
            .clear();

        let killed = outcome.killed;
        if killed.is_empty() {
            return;
        }
        // Запись заводят только те, про кого эпизод паузы ещё не рассказал.
        // Уведомление — про всех завершённых сейчас: запись у стоявшей цели уже
        // есть, но новость «цели завершены» от этого не исчезает.
        let fresh: Vec<MatchedProcess> = killed
            .iter()
            .filter(|process| !skip.contains(&process.pid))
            .cloned()
            .collect();

        let context = self.kill_context(settings, reason, None);
        self.reporter.report(&killed, &fresh, &context);
    }

    // --- восстановление после падения ---------------------------------------

    /// Учёт, доживший до нового запуска: SIGCONT всем, кто ещё стоит и остался
    /// тем же процессом (pid переиспользуются, и SIGCONT чужому недопустим).
    ///
    /// Пробы за этим стоянием нет, поэтому эпизод у него свой — но эпизод есть:
    /// остановил эти процессы weto, а «почему этот процесс стоял» спрашивают
    /// у журнала завершений, и молчать ему там нельзя. Запись журнала проверок
    /// отвечает на другой вопрос — что именно weto сделал на старте.
    pub fn recover_stopped(&self) {
        let settings = self.settings.settings();
        let fingerprint = self.network.snapshot().verdict_fingerprint();

        // Учёт не прочитался — обязательство не выполнено. Молча пустое чтение
        // неотличимо от «возобновлять нечего», поэтому след остаётся в журнале.
        if self.enforcer.ledger_was_corrupted() {
            self.record_check(
                CheckTrigger::StartupRecovery,
                CheckOutcome::LedgerUnreadable,
                &fingerprint,
                Some("учёт остановленных процессов не прочитан: возобновлять нечего".to_string()),
            );
        }

        let rules = settings.target_rules();
        let (outcome, scan) = self.enforcer.resume_orphans(&rules);
        if outcome.unresolved.is_empty() {
            return;
        }

        let mut names: HashMap<i32, String> = HashMap::new();
        let mut bases: HashMap<i32, MatchBasis> = HashMap::new();
        if !scan.is_empty() {
            for process in weto_core::process::matches(&scan.processes, &scan.rules) {
                names.insert(process.pid, process.target_name.clone());
                bases.insert(process.pid, process.matched_by);
            }
        }
        let parents: HashMap<i32, i32> = scan
            .processes
            .iter()
            .map(|process| (process.pid, process.parent_pid))
            .collect();

        let standing: Vec<RecoveredProcess> = outcome
            .unresolved
            .iter()
            .map(|entry| RecoveredProcess {
                process: MatchedProcess {
                    pid: entry.pid,
                    // Цель, снятая пользователем с охраны между запусками, по имени
                    // не находится — тогда именем служит сам бинарник, и это честнее
                    // пустой строки.
                    target_name: names.get(&entry.pid).cloned().unwrap_or_else(|| {
                        entry
                            .executable_path
                            .rsplit('/')
                            .next()
                            .unwrap_or_default()
                            .to_string()
                    }),
                    parent_pid: parents.get(&entry.pid).copied().unwrap_or_default(),
                    executable_path: entry.executable_path.clone(),
                    // Шеллом запись сделал не текущий разбор, а учёт: ради терминала
                    // цели этот процесс остановили в прошлой жизни weto.
                    matched_by: if entry.is_shell {
                        MatchBasis::Shell
                    } else {
                        bases.get(&entry.pid).copied().unwrap_or(MatchBasis::Rule)
                    },
                },
                stopped_at: entry.stopped_at,
            })
            .collect();

        {
            let mut inner = self.inner.lock().expect("состояние охраны");
            inner.pause.recovery_open = true;
            inner.pause.episode_reason = Some(RECOVERY_REASON_TEXT.to_string());
            for recovered in &standing {
                inner.pause.episode_pids.insert(recovered.process.pid);
                // Сигнал этим записям уже ушёл, поэтому следующее наблюдение —
                // их ответ, а не ожидание: иначе такт молча слал бы SIGCONT
                // по второму разу.
                inner
                    .pause
                    .signalled_for_resume
                    .insert(recovered.process.pid);
                if recovered.process.matched_by == MatchBasis::Shell {
                    continue;
                }
                inner.pause.paused.push(PausedProcess {
                    pid: recovered.process.pid,
                    target_name: recovered.process.target_name.clone(),
                    since: recovered.stopped_at,
                    // «Вернулось в фон» дописывает первое же наблюдение: сейчас
                    // известно только то, что процесс стоял.
                    is_backgrounded: false,
                });
            }
            inner.snapshot.paused = inner.pause.paused.clone();
        }

        let context = self.kill_context(&settings, RECOVERY_REASON_TEXT.to_string(), None);
        self.reporter.recovered(&standing, &context);

        let pids: Vec<i32> = standing.iter().map(|r| r.process.pid).collect();
        self.record_check(
            CheckTrigger::StartupRecovery,
            CheckOutcome::StandingProcessesRemain,
            &fingerprint,
            Some(format!(
                "учёт остановленных: процессы {pids:?} стояли на старте — \
                 продолжение отправлено, дальше их ведёт такт охраны"
            )),
        );
    }

    /// Штатный выход: замороженных целей не оставляем.
    ///
    /// Наблюдать последствия сигнала здесь уже нечем — такта больше не будет, —
    /// поэтому запись, которую SIGCONT не разрешил, остаётся в учёте и достаётся
    /// восстановлению при следующем запуске. Журнал говорит ровно то, что
    /// установлено: «не возобновлено» здесь было бы такой же неправдой, как
    /// «возобновлено», — стоящими записи показал обход, снятый ДО сигнала.
    pub fn shutdown(&self) {
        let settings = self.settings.settings();
        let outcome = self.enforcer.resume(None, &HashSet::new());
        let refused: Vec<i32> = outcome
            .results
            .iter()
            .filter(|result| !result.is_delivered())
            .map(|result| result.pid)
            .collect();
        let standing = standing_pids(&outcome.unresolved);

        let text = if outcome.is_complete() {
            "возобновлено: охрана остановлена".to_string()
        } else if !refused.is_empty() {
            Self::unresolved_episode_text(&standing, &refused)
        } else {
            format!(
                "не подтверждено: сигнал продолжения отправлен процессам {standing:?}, \
                 а охрана остановлена — результат наблюдать нечем, weto проверит их \
                 при следующем запуске"
            )
        };
        self.resolve_pause_episode(&settings, &text, None);

        let mut inner = self.inner.lock().expect("состояние охраны");
        let alive: HashSet<i32> = standing.iter().copied().collect();
        inner.pause.paused.retain(|p| alive.contains(&p.pid));
        // Фаза обязана уйти вместе с целями: «Пауза», оставленная после остановки,
        // тикала бы отсчётом до потолка, которого никто больше не считает.
        inner.machine = GuardMachine::default();
        inner.snapshot.phase = GuardPhase::Disabled;
        inner.snapshot.pause_deadline = None;
        inner.snapshot.paused = inner.pause.paused.clone();
    }

    // --- показания ----------------------------------------------------------

    /// Снимок для экрана: фаза, живые цели и стоящие. Заголовок, цвет щита
    /// и три строки объяснения строит сам экран из фазы через
    /// `weto_core::presentation` — снимок их не кеширует.
    fn publish(&self, phase: &GuardPhase, scan: &Scan) {
        let running = self.enforcer.running_in(scan);

        let mut inner = self.inner.lock().expect("состояние охраны");
        inner.snapshot.phase = phase.clone();
        inner.snapshot.running = running;
        inner.snapshot.paused = inner.pause.paused.clone();
        inner.snapshot.pause_deadline = phase.paused_since().map(|since| since + PAUSE_CEILING);
    }

    /// Текст, с которым закрывается эпизод у работающих целей.
    fn safe_outcome_text(&self, phase: &GuardPhase) -> String {
        match phase.reading() {
            Some(reading) => format!(
                "проверка завершилась безопасным выходом: {}, {}",
                reading.ip, reading.primary_country
            ),
            None => "проверка завершилась безопасным выходом".to_string(),
        }
    }

    /// Показания эпизода: они не показываются пользователю и нужны только выгрузке.
    fn kill_context(
        &self,
        settings: &Settings,
        reason: String,
        staleness: Option<VerdictStaleness>,
    ) -> KillContext {
        let inner = self.inner.lock().expect("состояние охраны");
        let reading = match &inner.last_reading {
            Some(reading) => GeoReadingPatch {
                ip: Some(reading.ip.clone()),
                country: Some(reading.primary_country.clone()),
                confirmed_country: reading.confirmed_country.clone(),
                confirm_source: reading.confirm_source.map(|s| s.name().to_string()),
            },
            None => GeoReadingPatch::default(),
        };
        let report = inner.last_report.clone();
        let network = inner.last_network.clone();
        drop(inner);

        KillContext {
            reason,
            reading,
            diagnostics: KillDiagnostics {
                staleness,
                outgoing_interface: network.outgoing.as_ref().map(|o| o.interface.clone()),
                outgoing_address: network.outgoing.as_ref().map(|o| o.address.clone()),
                has_network_path: report.as_ref().map(|r| r.has_network_path),
                vpn_app_entry: settings.vpn_app.as_ref().map(|app| app.entry.clone()),
                vpn_app_status: Some(format!("{:?}", self.vpn_app_status(settings))),
                verdict_origin: report.as_ref().map(|r| {
                    match r.outcome() {
                        GeoOutcome::Resolved(_) => "current",
                        _ => "established",
                    }
                    .to_string()
                }),
                services: report
                    .as_ref()
                    .map(|r| r.traces.clone())
                    .unwrap_or_default(),
                probed_at: report.as_ref().map(|r| r.checked_at),
                app_version: Some(env!("CARGO_PKG_VERSION").to_string()),
            },
        }
    }

    // --- проба --------------------------------------------------------------

    /// Запись о состоявшейся пробе: показания и трассы сервисов как есть.
    fn note_check(
        &self,
        trigger: CheckTrigger,
        outcome: &GeoOutcome,
        report: &GeoProbeReport,
        fingerprint: &str,
        milliseconds: u64,
    ) {
        let reading = match outcome {
            GeoOutcome::Resolved(reading) => Some(reading.clone()),
            _ => None,
        };
        let detail = match outcome {
            GeoOutcome::Resolved(_) => None,
            GeoOutcome::Degraded { detail, .. } => Some(detail.clone()),
            GeoOutcome::Unavailable(detail) => Some(detail.clone()),
            GeoOutcome::AddressChanged { observed, previous } => Some(format!(
                "адрес сменился: был {}, стал {observed}",
                previous.ip
            )),
        };

        self.checks.record(CheckEvent {
            id: new_check_id(),
            at: SystemTime::now(),
            trigger,
            outcome: if reading.is_some() {
                CheckOutcome::Answered
            } else {
                CheckOutcome::Failed
            },
            fingerprint: Some(fingerprint.to_string()),
            duration_milliseconds: Some(milliseconds),
            ip: report.ip.clone(),
            country: reading.as_ref().map(|r| r.primary_country.clone()),
            confirmed_country: reading.as_ref().and_then(|r| r.confirmed_country.clone()),
            confirm_source: reading
                .as_ref()
                .and_then(|r| r.confirm_source.map(|s| s.name().to_string())),
            services: report.traces.clone(),
            detail,
        });
    }

    fn record_check(
        &self,
        trigger: CheckTrigger,
        outcome: CheckOutcome,
        fingerprint: &str,
        detail: Option<String>,
    ) {
        self.checks.record(CheckEvent {
            id: new_check_id(),
            at: SystemTime::now(),
            trigger,
            outcome,
            fingerprint: Some(fingerprint.to_string()),
            duration_milliseconds: None,
            ip: None,
            country: None,
            confirmed_country: None,
            confirm_source: None,
            services: Vec::new(),
            detail,
        });
    }

    fn probe_trigger(&self, trigger: ProbeTrigger, revision: u64) -> CheckTrigger {
        if trigger == ProbeTrigger::Manual {
            CheckTrigger::Manual
        } else {
            self.staleness_trigger(revision)
        }
    }

    /// Повод пробы выводится из того, что именно перестало быть свежим: ревизия
    /// настроек или отпечаток выхода.
    fn staleness_trigger(&self, revision: u64) -> CheckTrigger {
        let inner = self.inner.lock().expect("состояние охраны");
        match inner.established.as_ref() {
            Some(established) if established.revision != revision => CheckTrigger::SettingsChange,
            _ => CheckTrigger::NetworkChange,
        }
    }

    /// Чем прежний вердикт перестал описывать наш выход — на этот самый момент.
    ///
    /// Считается из установленного вердикта и текущего отпечатка, а не
    /// запоминается: разбор обязан описывать момент своего применения, а не
    /// прошлое объявление. Отказ сервисов установленный вердикт не заменяет,
    /// поэтому сравнивать всегда есть с чем.
    fn staleness_now(&self, revision: u64, fingerprint: &str) -> VerdictStaleness {
        let inner = self.inner.lock().expect("состояние охраны");
        VerdictStaleness::new(
            inner.established.as_ref().map(|e| e.revision),
            revision,
            inner.established.as_ref().map(|e| e.fingerprint.clone()),
            fingerprint.to_string(),
        )
    }

    /// Есть ли ответ про этот путь при этих настройках.
    fn has_verdict(&self, revision: u64, fingerprint: &str) -> bool {
        let inner = self.inner.lock().expect("состояние охраны");
        inner
            .verdict
            .as_ref()
            .is_some_and(|(known, path)| *known == revision && path == fingerprint)
    }

    fn established_reading(&self, fingerprint: &str) -> Option<GeoReading> {
        let inner = self.inner.lock().expect("состояние охраны");
        inner
            .established
            .as_ref()
            .filter(|e| e.fingerprint == fingerprint)
            .map(|e| e.reading.clone())
    }

    /// Пора ли обновлять гео. Отдельно от окна коалесценции: то гасит всплески
    /// событий, это задаёт частоту запросов.
    fn geo_schedule_due(&self) -> bool {
        let inner = self.inner.lock().expect("состояние охраны");
        match inner.last_probe_finished {
            None => true,
            Some(at) => at.elapsed() >= GEO_PROBE_INTERVAL,
        }
    }

    fn coalescing_window_passed(&self) -> bool {
        let inner = self.inner.lock().expect("состояние охраны");
        match inner.last_probe_finished {
            None => true,
            Some(at) => at.elapsed() >= self.coalesce_window,
        }
    }

    /// Запрос к сервисам. Повторное нажатие в полёте запроса второго не порождает.
    fn probe_and_store(
        &self,
        settings: &Settings,
        fingerprint: &str,
        trigger: CheckTrigger,
    ) -> Option<GeoOutcome> {
        if self.probe_in_flight.swap(true, Ordering::SeqCst) {
            // Ровно этот случай и означает «нажал пять раз, а запрос так и не ушёл».
            self.record_check(
                trigger,
                CheckOutcome::SkippedProbeInFlight,
                fingerprint,
                None,
            );
            return None;
        }

        let token = self.secrets.load().ok().flatten();
        let started = Instant::now();
        let report = self.geo.probe(token.as_deref());
        let elapsed = started.elapsed().as_millis() as u64;
        let outcome = self.admissible_outcome(&report, fingerprint);

        self.note_check(trigger, &outcome, &report, fingerprint, elapsed);

        {
            let mut inner = self.inner.lock().expect("состояние охраны");
            if let GeoOutcome::Resolved(reading) = &outcome {
                inner.established = Some(Established {
                    reading: reading.clone(),
                    fingerprint: fingerprint.to_string(),
                    revision: settings.revision,
                });
                inner.last_reading = Some(reading.clone());
                inner.announced_loss = None;
            }
            if let GeoOutcome::Degraded { previous, .. } = &outcome {
                inner.last_reading = Some(previous.clone());
            }
            inner.verdict = Some((settings.revision, fingerprint.to_string()));
            inner.last_probe_finished = Some(Instant::now());
            inner.last_report = Some(report.clone());
            // Отчёт отдаётся и при отказе: экран обязан показать, кто именно молчал.
            inner.snapshot.report = Some(report);
        }

        self.probe_in_flight.store(false, Ordering::SeqCst);
        Some(outcome)
    }

    /// Запущено ли выбранное VPN-приложение.
    ///
    /// Обход `/proc` тот же, что у целей: правило приложения приходит из настроек
    /// уже разрешённым, а в список целей не попадает никогда — завершать свой
    /// источник защиты охрана не имеет права.
    fn vpn_app_status(&self, settings: &Settings) -> VpnAppStatus {
        let Some(rule) = settings.vpn_app_rule() else {
            return VpnAppStatus::NotChosen;
        };
        if self.enforcer.is_running(&rule) {
            VpnAppStatus::Running
        } else {
            VpnAppStatus::NotRunning
        }
    }

    /// Что из отчёта годится в основание вердикта.
    ///
    /// ipinfo ответил — берём его ответ. ipinfo молчит — смотрим, назвал ли
    /// резервный сервис наш адрес: совпал с адресом прошлого вердикта, значит
    /// страна та же и перепроверять нечего. Это доказательство неизменности,
    /// а не снисхождение к давности, и каждый круг доказывается заново.
    ///
    /// Сменился отпечаток сети — снисхождения нет ни при каком совпадении адреса:
    /// вердикт при смене пути недействителен по построению.
    fn admissible_outcome(&self, report: &GeoProbeReport, fingerprint: &str) -> GeoOutcome {
        let outcome = report.outcome();
        let GeoOutcome::Unavailable(detail) = &outcome else {
            return outcome;
        };

        let inner = self.inner.lock().expect("состояние охраны");
        let Some(established) = inner
            .established
            .as_ref()
            .filter(|e| e.fingerprint == fingerprint)
        else {
            return outcome;
        };
        let Some(address) = report.ip.as_deref() else {
            return outcome;
        };

        if address != established.reading.ip {
            return GeoOutcome::AddressChanged {
                observed: address.to_string(),
                previous: established.reading.clone(),
            };
        }
        GeoOutcome::Degraded {
            previous: established.reading.clone(),
            detail: detail.clone(),
        }
    }

    /// Забыть показания, снятые при другом состоянии сети.
    ///
    /// Прочерк честнее устаревшего ответа: адрес и страна упавшего туннеля,
    /// оставшиеся на экране, читаются как «я всё ещё там», хотя пользователь
    /// уже вышел в сеть напрямую.
    fn forget_report(&self) {
        let mut inner = self.inner.lock().expect("состояние охраны");
        inner.snapshot.report = None;
        inner.last_report = None;
        inner.last_reading = None;
    }
}

fn standing_pids(entries: &[weto_config::stopped::StoppedProcess]) -> Vec<i32> {
    entries.iter().map(|entry| entry.pid).collect()
}

/// Идентификатор записи проверки. UUID сюда тянуть незачем: хватает монотонного
/// счётчика с отметкой времени — записи живут в одном файле одного пользователя.
fn new_check_id() -> String {
    use std::sync::atomic::AtomicU64;
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let order = COUNTER.fetch_add(1, Ordering::Relaxed);
    let since_epoch = SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or_default();
    format!("check-{since_epoch:x}-{order:x}")
}
