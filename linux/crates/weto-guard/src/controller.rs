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
//! # Проба идёт своей дорожкой
//!
//! Проход, решивший спросить сеть, запроса не ждёт: он применяет к процессам то,
//! что известно сейчас, и отпускает пробу на фоновую дорожку. Ответ возвращается
//! своим проходом — вход редьюсеру и своё применение. Иначе цель, запущенная под
//! паузой или под запретом, жила бы всё время ожидания ipinfo: такт идёт раз
//! в секунду против пятисекундного таймаута, а под красным статусом — раз
//! в 250 мс ровно ради новорождённых. Порт macOS, где проба — `Task`,
//! а `applyLatestNetworkOutcome` и есть этот второй проход.
//!
//! # Свежесть вердикта
//!
//! Сетевой вердикт годен, пока не изменились две вещи: ревизия настроек
//! и отпечаток снимка сети. Отпечаток берётся по выбранному интерфейсу, а не по
//! всей сети: иначе чужой VPN, переподключившийся сам по себе, стоил бы
//! пользователю целей. Потеря свежести целей больше не трогает — она просит пробу.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::Ordering;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant, SystemTime};

use weto_config::settings::Settings;
use weto_core::check::{CheckEvent, CheckOutcome, CheckTrigger};
use weto_core::diagnostics::{GeoReadingPatch, KillContext, KillDiagnostics, VerdictStaleness};
use weto_core::geo::{GeoOutcome, GeoProbeReport, GeoReading};
use weto_core::guard_machine::{GuardAction, GuardInput, GuardMachine, GuardPhase, PAUSE_CEILING};
use weto_core::network::NetworkSnapshot;
use weto_core::network::VpnAppStatus;
use weto_core::pause_plan::{PausedProcess, RecoveredProcess};
use weto_core::policy::GuardSignals;
use weto_core::policy::{decide, decide_local, GuardDecision, UnsafeEvidence};
use weto_core::process::{MatchBasis, MatchedProcess, RunningTarget};
use weto_sys::background::{BackgroundDispatching, ThreadDispatcher};
use weto_sys::geo_probe::GeoProbing;
use weto_sys::network_snapshot::NetworkSnapshotReading;
use weto_sys::secret_store::SecretStoring;

use crate::enforcer::{ProcessEnforcer, ResumeOutcome, Scan};

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

/// Сигнал снятой с охраны цели ушёл, а результат ещё не наблюдался. Ровно то же
/// различие, что у штатного выхода: `kill(SIGCONT)` возвращает 0 и фоновому заданию,
/// которое тут же встанет обратно, — «продолжен» тут было бы заявлением
/// о ненаблюдённом. Дословно как на macOS.
pub const RELEASE_SIGNALLED_TEXT: &str =
    "не подтверждено: цель снята с охраны, продолжение отправлено — \
     результат ещё не наблюдался";

/// Обязательство исполнено и наблюдено: процесс идёт (или его больше нет),
/// и запись ушла из учёта. Дословно как на macOS.
pub const RELEASED_TEXT: &str = "продолжен: цель снята с охраны";

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

    /// Записи, чьё стояние кончилось раньше эпизода: цель сняли с охраны, и держать
    /// процесс стало не за чем. Исход у них свой — общий исход эпизода их не касается
    /// и переписать его не имеет права.
    fn released(&self, _pids: &[i32], _outcome: &str, _context: &KillContext) {}

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
    /// pid, освобождённые снятием цели с охраны. Их стояние кончилось раньше эпизода
    /// и по своей причине, поэтому исход у них свой — а общий исход эпизода их записи
    /// не трогает: «возобновлено проверкой» и «завершено по доказательству» не про них.
    released_from_guard: HashSet<i32>,
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

/// Одна проба за раз — и способ дождаться её ответа.
///
/// Отменять летящую пробу нельзя: пока вердикт несвеж, такт заново просит её
/// каждую секунду, а таймаут ipinfo — пять. На медленном канале снятие
/// не оставило бы вердикту ни одного шанса. Поэтому вторая проба не начинается,
/// а пропускается, и пропуск — не ошибка, а рабочее состояние.
#[derive(Default)]
struct ProbeGate {
    in_flight: Mutex<bool>,
    answered: Condvar,
}

impl ProbeGate {
    /// Занять дорожку. `false` — она уже занята, и второго запроса не будет.
    fn take(&self) -> bool {
        let mut in_flight = self.in_flight.lock().expect("дорожка пробы");
        if *in_flight {
            return false;
        }
        *in_flight = true;
        true
    }

    fn release(&self) {
        *self.in_flight.lock().expect("дорожка пробы") = false;
        self.answered.notify_all();
    }

    fn is_busy(&self) -> bool {
        *self.in_flight.lock().expect("дорожка пробы")
    }

    /// Дождаться ответа летящей пробы. Нужно ровно тем, кому без ответа нечего
    /// показать: `wetod --check` печатает страну, а не обещание спросить.
    fn wait(&self) {
        let mut in_flight = self.in_flight.lock().expect("дорожка пробы");
        while *in_flight {
            in_flight = self.answered.wait(in_flight).expect("ожидание пробы");
        }
    }
}

/// Дорожка занята, пока живёт этот сторож: ответ, отказ и паника отпускают её
/// одинаково.
struct InFlight<'a>(&'a ProbeGate);

impl Drop for InFlight<'_> {
    fn drop(&mut self) {
        self.0.release();
    }
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
    /// Куда уходит проба, чтобы такт её не ждал. Граница, а не деталь: тесту
    /// нужен детерминированный порядок «проход прошёл — ответ пришёл».
    probes: Box<dyn BackgroundDispatching>,
    inner: Mutex<Inner>,
    probe: ProbeGate,
    /// Ворота применения решения к процессам — и признак штатного выхода под
    /// теми же воротами.
    ///
    /// Такт идёт в своём потоке, а выход зовёт GTK из главного, и признаком
    /// одним их не развести: такт, уже применяющий решение, успевал послать
    /// SIGSTOP **после** последнего SIGCONT, а размораживать цель после выхода
    /// некому — такта больше не будет. Ворота дают обе половины сразу: такт,
    /// начавшийся после выхода, не делает ничего, а такт, уже вошедший
    /// в применение, выход дожидается. Держатся они ровно на применение (обход,
    /// сигналы, учёт), а не на весь такт: ждать за ними пробу значило бы держать
    /// выход приложения пять секунд таймаута ipinfo.
    ///
    /// Порядок захвата всегда «ворота, потом `inner`» — обратного нет нигде.
    ///
    /// `true` — выход уже был. Воронка выхода одна, но удаление зовёт его
    /// и руками (цели обязаны продолжиться раньше, чем исчезнет учёт), и без
    /// этого признака второй вызов слал бы SIGCONT по второму разу и заново
    /// сохранял бы уже удалённый файл учёта.
    enforcement: Mutex<bool>,
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
            probes: Box::new(ThreadDispatcher::named("weto-probe")),
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
            probe: ProbeGate::default(),
            enforcement: Mutex::new(false),
            coalesce_window: COALESCE_WINDOW,
            now: Box::new(SystemTime::now),
        }
    }

    /// Дорожка пробы задаётся снаружи только ради тестов: им нужен
    /// детерминированный порядок «проход прошёл — ответ пришёл», а не гонка
    /// с планировщиком потоков.
    pub fn with_probes(mut self, probes: Box<dyn BackgroundDispatching>) -> GuardController {
        self.set_probes(probes);
        self
    }

    /// То же самое для стенда, собравшего охрану раньше, чем он выбрал дорожку.
    pub fn set_probes(&mut self, probes: Box<dyn BackgroundDispatching>) {
        self.probes = probes;
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
        self.set_clock(now);
        self
    }

    /// То же самое для стенда, который собрал охрану раньше, чем узнал про часы.
    pub fn set_clock(&mut self, now: Clock) {
        self.now = now;
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

    /// Штатный выход уже был: применять решение к процессам больше нельзя
    /// никому. По нему поток охраны и выходит из своего цикла — крутиться
    /// пустым тактом ему незачем.
    pub fn is_shut_down(&self) -> bool {
        *self.enforcement.lock().expect("ворота применения")
    }

    /// Сколько цели ещё могут стоять. `None` — не стоят.
    pub fn remaining_pause(&self) -> Option<Duration> {
        self.inner
            .lock()
            .expect("состояние охраны")
            .machine
            .remaining_pause((self.now)())
    }

    /// Идёт ли прямо сейчас запрос к сервисам. Спрашивает интерфейс: на месте
    /// кнопки проверки крутится индикатор, пока ответа нет.
    pub fn is_probing(&self) -> bool {
        self.probe.is_busy()
    }

    /// Дождаться ответа летящей пробы.
    ///
    /// Охране это не нужно никогда — она живёт тактами, — но разовому вопросу
    /// вроде `wetod --check` без ответа нечего напечатать.
    pub fn await_probe(&self) {
        self.probe.wait();
    }

    /// Штатный такт охраны.
    pub fn tick(self: &Arc<Self>) -> GuardPhase {
        self.run(ProbeTrigger::Scheduled)
    }

    /// Проверка по кнопке.
    ///
    /// Спрашивает «где я сейчас», а не «нужна ли охране проверка»: запрос
    /// уходит и тогда, когда судьба целей решена локально. Экономия запросов —
    /// свойство штатного тика; на кнопке она означала бы молчание экрана ровно
    /// в тот момент, когда пользователь хочет увидеть свою страну.
    pub fn probe_now(self: &Arc<Self>) -> GuardPhase {
        self.run(ProbeTrigger::Manual)
    }

    // --- такт ---------------------------------------------------------------

    /// Один проход охраны: сколько угодно входов редьюсеру — и ровно одно
    /// применение к процессам, после последнего входа.
    ///
    /// Входов у такта бывает несколько (`Reassessment` перед `Tick`), и это дело
    /// редьюсера: он описывает знание о выходе, а знание за такт меняется не один
    /// раз. Применение — дело процессов, и оно одно: обход `/proc` стоит
    /// миллисекунды, а второй проход посылал бы сигналы по данным, которые первый
    /// уже изменил, — цель, отпущенную первым, второй вычёркивал из учёта тем же
    /// тактом, послав ей SIGCONT по второму разу.
    ///
    /// Проба уходит последней, уже после применения: ответ — это вход `Verdict`,
    /// и приносит его свой проход, а не этот. Ждать его здесь значило бы держать
    /// цели, запущенные под паузой или под запретом, пять секунд таймаута ipinfo.
    fn run(self: &Arc<Self>, trigger: ProbeTrigger) -> GuardPhase {
        // Такт, начавшийся после штатного выхода, не делает ничего: цели уже
        // продолжены, а тронуть он их может только в одну сторону — обратно
        // в стояние, из которого их никто не выведет.
        if self.is_shut_down() {
            return self.phase();
        }
        let settings = self.settings.settings();
        let network = self.network.snapshot();
        let config = settings.guard_config();
        let fingerprint = network.verdict_fingerprint();
        self.inner.lock().expect("состояние охраны").last_network = network.clone();

        // Единственный обход процессов этого прохода. Дальше он расходится всем,
        // кому нужен: статусу VPN-приложения, сигналам, списку живых целей,
        // наблюдению за учётом и показаниям журнала. Между ним и сигналами лежит
        // только работа редьюсера — в память и без единого syscall; запрос к сети
        // ушёл бы после применения, а не до.
        let scan = self.enforcer.scan(&settings.target_rules());

        if !settings.is_enabled || !config.has_targets() {
            self.inner.lock().expect("состояние охраны").announced_loss = None;
            return self.dispatch(GuardInput::Disarmed, &settings, &scan);
        }

        let vpn = self.vpn_app_status(&settings, &scan);
        let has_verdict = self.has_verdict(settings.revision, &fingerprint);

        // Локальное доказательство применяется сразу, до сети: закрытый клиент —
        // завершение. Жизни целям сетевой запрос не продлевает.
        if let Some(GuardDecision::Kill(evidence)) = decide_local(settings.is_enabled, vpn, &config)
        {
            let phase = self.dispatch(GuardInput::Evidence(evidence), &settings, &scan);
            if !has_verdict {
                // Экран не должен показывать защиту, которой нет; проба нужна
                // ради показаний.
                self.forget_report();
            }
            if trigger == ProbeTrigger::Manual || (!has_verdict && self.coalescing_window_passed())
            {
                let reason = self.probe_trigger(trigger, settings.revision);
                self.start_probe(&settings, &fingerprint, reason);
            }
            return phase;
        }

        if !has_verdict {
            // Вердикта про этот путь нет: объявляем потерю и просим пробу — цели
            // при этом работают, паузу принесёт только плохой результат. Потолок
            // считает лишь `Tick`, поэтому он идёт тем же тактом: пауза, начатая
            // до смены пути, иначе не доехала бы до завершения.
            self.announce_loss(&settings, &fingerprint);
            let phase = self.enforce(&settings, &scan);
            if trigger == ProbeTrigger::Manual || self.coalescing_window_passed() {
                let reason = self.probe_trigger(trigger, settings.revision);
                self.start_probe(&settings, &fingerprint, reason);
            }
            return phase;
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
            self.feed(GuardInput::Reassessment { decision, reading });
        }

        self.feed(GuardInput::Tick);
        let phase = self.enforce(&settings, &scan);

        // Расписание гео: страна выхода меняется и на неизменном пути. Пока цели
        // стоят, ритм тот же — проба и есть путь из паузы.
        if trigger == ProbeTrigger::Manual || self.geo_schedule_due() {
            let reason = if trigger == ProbeTrigger::Manual {
                CheckTrigger::Manual
            } else {
                CheckTrigger::Schedule
            };
            self.start_probe(&settings, &fingerprint, reason);
        }
        phase
    }

    /// Объявление потери вердикта: цели не трогаем, потолок паузы считается тем же
    /// тактом — `Tick` уезжает редьюсеру здесь, а применяет его решение
    /// единственное на такт `enforce`.
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
        self.feed(GuardInput::Tick);
    }

    /// Ответ пробы, пропущенный через политику, — редьюсеру.
    ///
    /// Применяет его не этот шаг, а `enforce` в конце прохода ответа: вход
    /// и применение разделены так же, как у такта. Разбор свежести поэтому гасит
    /// тоже `enforce`: достаться он обязан эпизоду, который этот результат заведёт.
    fn feed_verdict(
        &self,
        settings: &Settings,
        outcome: GeoOutcome,
        vpn: VpnAppStatus,
        fingerprint: &str,
    ) {
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

        self.feed(GuardInput::Verdict {
            decision,
            geo: outcome,
        });
    }

    // --- применение фазы ----------------------------------------------------

    /// Вход уезжает редьюсеру — и только ему: процессов этот шаг не касается.
    ///
    /// Входов за такт бывает несколько, и каждый обязан быть применён редьюсером:
    /// знание о выходе за такт меняется не один раз. А вот сигналы, учёт и журнал
    /// за такт случаются единожды — их делает `enforce`.
    ///
    /// Ворота берутся и здесь: после штатного выхода редьюсеру не место двигаться
    /// вовсе — фаза у остановленной охраны обнулена, и такт, доехавший сюда следом
    /// за выходом, вернул бы на экран «Пауза» с отсчётом, которого никто не считает.
    fn feed(&self, input: GuardInput) {
        let gate = self.enforcement.lock().expect("ворота применения");
        if *gate {
            return;
        }
        let moment = (self.now)();
        let mut inner = self.inner.lock().expect("состояние охраны");
        // Эффект перехода здесь не нужен: применяется действие текущей фазы,
        // и на переходе оно даёт ровно то же самое. Редьюсеру важно, что
        // вход применён, — фаза после этого и есть решение.
        inner.machine.apply(input, moment);
    }

    /// Решение редьюсера — процессам, а происшедшее — журналу. Один раз на проход,
    /// после последнего входа.
    ///
    /// Обход процессов на весь проход один, и приезжает он сюда готовым: и статус
    /// VPN-приложения, и сигналы, и список живых целей, и наблюдение за учётом,
    /// и показания журнала обязаны описывать один и тот же момент. Второе чтение
    /// `/proc` — не только лишние миллисекунды: оно описывает другой момент,
    /// и «приложение запущено» в записи журнала могло бы противоречить улике,
    /// по которой цели встали.
    fn enforce(&self, settings: &Settings, scan: &Scan) -> GuardPhase {
        // Ворота на всё применение: сигналы и учёт — один шаг относительно
        // штатного выхода. Такт, вошедший сюда раньше выхода, выход дожидается;
        // такт, подошедший после, разворачивается здесь — проба, начатая
        // до выхода, иначе ставила бы цели на паузу уже после последнего SIGCONT.
        let gate = self.enforcement.lock().expect("ворота применения");
        if *gate {
            return self.phase();
        }

        let phase = self.phase();

        // Применяется действие фазы, а не эффект перехода: цель, родившаяся
        // под паузой или под запретом, перехода не вызывает, и поймать её больше
        // нечем — живого системного события про запуск терминального процесса
        // без Endpoint Security не существует, а под красным статусом такт
        // и идёт учащённо ровно ради этого. Порт `GuardVM.applyCurrentAction`
        // с macOS, где то же делает сторож.
        match phase.action() {
            GuardAction::Pause => self.pause_targets(scan, settings, &phase),
            GuardAction::Terminate => {
                if let GuardPhase::Danger(evidence) = &phase {
                    self.terminate_targets(scan, settings, evidence);
                }
            }
            // Снятие паузы разбирается ниже, в ветке работающих целей:
            // обязательство держится до наблюдения, и разбирает его каждый проход
            // с работающими целями, а не только тот, что принёс переход.
            GuardAction::Run => {}
        }

        if phase.action() == GuardAction::Run {
            // Цели снова работают — эпизод закрыт, и следующее завершение будет
            // первым, а не «запуском запрещён».
            let context = self.kill_context(settings, self.safe_outcome_text(&phase), None, scan);
            self.reporter.episode_finished(&context);
            self.settle_resume(scan, settings, &phase);
        }

        // Разбор свежести жил ровно до применения: эпизод, ради которого его
        // считали, уже заведён, а следующему проходу он рассказал бы про чужой
        // момент.
        self.inner
            .lock()
            .expect("состояние охраны")
            .pending_staleness = None;

        self.publish(&phase, scan);
        phase
    }

    /// Вход и немедленное применение — для того, кто приходит не тактом.
    ///
    /// Вход у такого прохода ровно один, и применение у него своё: локальное
    /// доказательство закрытого клиента обязано дойти до целей **до** сети,
    /// а не после пяти секунд таймаута ipinfo.
    fn dispatch(&self, input: GuardInput, settings: &Settings, scan: &Scan) -> GuardPhase {
        self.feed(input);
        self.enforce(settings, scan)
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

        // Пилюли мало: цель, снятую с охраны, надо ещё и отпустить. Этим же проходом,
        // а не исходом эпизода — до него процесс стоял бы уже ничьим.
        self.release_unguarded(&outcome.matched, scan, settings);

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

        let context = self.kill_context(settings, reason, staleness, scan);
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

    /// Цель, снятую с охраны, отпускаем немедленно: weto не держит того, кого больше
    /// не сторожит.
    ///
    /// Повод стоять у записи учёта ровно один — правило, под которое она попала.
    /// Правило убрали — повода нет, и ждать исхода эпизода (до минуты потолка)
    /// значит держать замороженным процесс, про который пользователь уже сказал
    /// «это не моё». Отпускает `ProcessEnforcer::release`: он же решает, можно ли
    /// отпустить шелл, и шлёт сигналы в обратном стоп-порядке.
    ///
    /// Журналу дописывается свой исход, а не эпизодный: стояние этой записи кончилось
    /// раньше эпизода и по другой причине. Исходов два, потому что установлено бывает
    /// разное: сигнал отправлен — это одно, наблюдение показало процесс идущим —
    /// другое. Пока наблюдения нет, запись из учёта не уходит, и обязательство
    /// исполняет следующий проход.
    fn release_unguarded(&self, guarded: &[MatchedProcess], scan: &Scan, settings: &Settings) {
        let outcome = self.enforcer.release(guarded, Some(scan));
        if outcome.is_empty() {
            return;
        }

        let observed: HashSet<i32> = outcome.released.iter().copied().collect();
        let (pending, reason, staleness) = {
            let mut inner = self.inner.lock().expect("состояние охраны");
            for pid in &observed {
                inner.pause.stop_answers.remove(pid);
                inner.pause.signalled_for_resume.remove(pid);
            }
            // Пилюля уходит с сигналом, а не с наблюдением: она про стоящую **цель**,
            // а целью этот процесс уже не является — кнопке «Показать терминал» под ним
            // нечего показывать, и отсчёт до потолка считается не про него.
            let freed: HashSet<i32> = outcome.freed.iter().map(|entry| entry.pid).collect();
            inner
                .pause
                .paused
                .retain(|paused| !freed.contains(&paused.pid));

            // Запись про отправленный сигнал пишется один раз: проход идёт раз
            // в четверть секунды, и повторять в журнале одно и то же — значит
            // писать файл впустую.
            let pending: Vec<i32> = outcome
                .freed
                .iter()
                .map(|entry| entry.pid)
                .filter(|pid| {
                    !observed.contains(pid) && !inner.pause.released_from_guard.contains(pid)
                })
                .collect();
            inner.pause.released_from_guard.extend(freed);

            let reason = inner
                .pause
                .episode_reason
                .clone()
                .unwrap_or_else(|| RECOVERY_REASON_TEXT.to_string());
            let staleness = inner.pause.staleness.clone();
            (pending, reason, staleness)
        };

        let context = self.kill_context(settings, reason, staleness, scan);
        if !pending.is_empty() {
            self.reporter
                .released(&pending, RELEASE_SIGNALLED_TEXT, &context);
        }
        if !outcome.released.is_empty() {
            self.reporter
                .released(&outcome.released, RELEASED_TEXT, &context);
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
            self.resolve_pause_episode(settings, &self.resumed_episode_text(phase), None, scan);
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
        self.resolve_pause_episode(settings, &text, None, scan);
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
        scan: &Scan,
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
                inner.pause.released_from_guard.clear();
            }
            (open, reason, staleness)
        };
        if !open {
            return;
        }
        let context = self.kill_context(settings, reason, staleness, scan);
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
            scan,
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

        let context = self.kill_context(settings, reason, None, scan);
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
        // Восстановление — то же применение к процессам, и идти вперемежку
        // со штатным выходом ему нельзя: выход, случившийся посреди него,
        // не увидел бы половину учёта.
        let gate = self.enforcement.lock().expect("ворота применения");
        if *gate {
            return;
        }

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

        let context = self.kill_context(&settings, RECOVERY_REASON_TEXT.to_string(), None, &scan);
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
    ///
    /// Второй вызов не делает ничего. Выход проходит одной воронкой, но удаление
    /// зовёт его и руками, раньше сноса учёта, — а повтор без этого стоил бы
    /// второго SIGCONT (учёт-то не опустел: наблюдать результат нечем)
    /// и сохранения уже удалённого файла учёта.
    ///
    /// Ворота берутся до всего: такт, уже применяющий решение, обязан
    /// закончиться раньше последнего SIGCONT, а начавшийся после — не начаться
    /// вовсе. Иначе SIGSTOP уходил бы вслед за выходом, и цель оставалась
    /// стоять до следующего запуска weto.
    pub fn shutdown(&self) {
        let mut gate = self.enforcement.lock().expect("ворота применения");
        if *gate {
            return;
        }
        *gate = true;
        let settings = self.settings.settings();
        let (scan, outcome) = self.resume_from_ledger(&settings);
        let standing = standing_pids(&outcome.unresolved);
        let text = Self::shutdown_episode_text(&outcome, &standing);
        self.resolve_pause_episode(&settings, &text, None, &scan);

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

    /// Обход и продолжение всех записей учёта — общая дорога у штатного выхода
    /// и у подтверждения возобновления.
    ///
    /// Обход тот же самый, что уедет показаниям журнала: стоящими записи
    /// показывает снимок, снятый ДО сигнала. `skipping` пуст намеренно —
    /// последний сигнал получают и те записи, которым такт досылать перестал
    /// (`RESUME_RETRY_LIMIT`): обязательство исполняют завершение и выход.
    fn resume_from_ledger(&self, settings: &Settings) -> (Scan, ResumeOutcome) {
        let scan = self.enforcer.scan(&settings.target_rules());
        let outcome = self.enforcer.resume(Some(&scan), &HashSet::new());
        (scan, outcome)
    }

    /// Чем кончился последний SIGCONT штатного выхода. Журнал говорит ровно то,
    /// что установлено: наблюдать результат нечем, и «не возобновлено» было бы
    /// такой же неправдой, как «возобновлено».
    fn shutdown_episode_text(outcome: &ResumeOutcome, standing: &[i32]) -> String {
        let refused: Vec<i32> = outcome
            .results
            .iter()
            .filter(|result| !result.is_delivered())
            .map(|result| result.pid)
            .collect();

        if outcome.is_complete() {
            "возобновлено: охрана остановлена".to_string()
        } else if !refused.is_empty() {
            Self::unresolved_episode_text(standing, &refused)
        } else {
            format!(
                "не подтверждено: сигнал продолжения отправлен процессам {standing:?}, \
                 а охрана остановлена — результат наблюдать нечем, weto проверит их \
                 при следующем запуске"
            )
        }
    }

    /// Досылает SIGCONT оставшимся записям учёта и возвращает тех, кого обход
    /// всё ещё показывает стоящими.
    ///
    /// Зовётся после `shutdown()` — и только удалением. Всюду ещё обязательство,
    /// которое выход исполнить не смог, достаётся следующему запуску: учёт цел,
    /// и `recover_stopped()` разберёт его как обычно. Удаление — единственный
    /// выход, после которого следующего запуска не будет вовсе: вместе
    /// с приложением исчезает и учёт, и процесс, не поднявшийся с последнего
    /// сигнала, остаётся замороженным навсегда. Поэтому здесь обязательство
    /// исполняет наблюдение: сигнал уходит снова, пока ядро не покажет процесс
    /// идущим, а не поднявшихся вызывающий обязан назвать пользователю.
    ///
    /// Ворота применения не снимает — такту после выхода делать нечего, — и исход
    /// эпизода повторно не переписывает: одной записи от `shutdown()` довольно,
    /// а второй она превратилась бы из «не подтверждено» в другой ответ про то же
    /// самое стояние.
    pub fn confirm_resumed(&self) -> Vec<weto_config::stopped::StoppedProcess> {
        let settings = self.settings.settings();
        let (_, outcome) = self.resume_from_ledger(&settings);
        outcome.unresolved
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
    ///
    /// Обход берётся у прохода: статус VPN-приложения в записи обязан описывать
    /// тот же момент, что и сигналы, — иначе журнал объяснял бы завершение уликой
    /// из одного мгновения и статусом из другого.
    fn kill_context(
        &self,
        settings: &Settings,
        reason: String,
        staleness: Option<VerdictStaleness>,
        scan: &Scan,
    ) -> KillContext {
        let vpn = self.vpn_app_status(settings, scan);
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
                vpn_app_status: Some(format!("{:?}", vpn)),
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
    ///
    /// Исход приходит параметром, а не выводится из ответа: ответ бывает годным
    /// сам по себе и всё равно отброшенным — путь сменился или настройки успели
    /// измениться, пока проба летела.
    fn note_check(
        &self,
        trigger: CheckTrigger,
        result: CheckOutcome,
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
            outcome: result,
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

    /// Отпустить пробу на её дорожку. Проход не ждёт ни запроса, ни ответа.
    ///
    /// Ревизия настроек и отпечаток выхода снимаются здесь, на старте пробы:
    /// ответ, вернувшийся в изменившийся мир, описывает уже не нас, и применять
    /// его нельзя — ни как доказательство, ни как safe.
    fn start_probe(
        self: &Arc<Self>,
        settings: &Settings,
        fingerprint: &str,
        trigger: CheckTrigger,
    ) {
        if !self.probe.take() {
            // Ровно этот случай и означает «нажал пять раз, а запрос так и не ушёл».
            // Записывается только нажатие: автоматические поводы приходят каждый
            // такт, и их пропуски вытеснили бы из полусотни записей ровно ту, ради
            // которой журнал и ведётся.
            if trigger == CheckTrigger::Manual {
                self.record_check(
                    trigger,
                    CheckOutcome::SkippedProbeInFlight,
                    fingerprint,
                    None,
                );
            }
            return;
        }

        let controller = Arc::clone(self);
        let revision = settings.revision;
        let fingerprint = fingerprint.to_string();
        self.probes.dispatch(Box::new(move || {
            controller.probe_and_apply(revision, fingerprint, trigger);
        }));
    }

    /// Запрос к сервисам и его ответ — на фоновой дорожке.
    ///
    /// Дорожка освобождается вместе со сторожем: и ответом, и отказом, и паникой.
    /// Пока она занята, второй запрос не уходит — у подтверждающего сервиса лимит,
    /// а снимать летящую пробу нельзя.
    fn probe_and_apply(&self, revision: u64, fingerprint: String, trigger: CheckTrigger) {
        let _in_flight = InFlight(&self.probe);

        let token = self.secrets.load().ok().flatten();
        let started = Instant::now();
        let report = self.geo.probe(token.as_deref());
        let elapsed = started.elapsed().as_millis() as u64;

        // Ход расписания меряет ответ, а не отправка: частота запросов считается
        // от того момента, когда сервисы освободились.
        self.inner
            .lock()
            .expect("состояние охраны")
            .last_probe_finished = Some(Instant::now());

        self.apply_probe(report, revision, fingerprint, trigger, elapsed);
    }

    /// Ответ пробы — своим проходом: вход редьюсеру и своё применение.
    ///
    /// Барьеров два, и оба сняты на старте пробы. Ревизия настроек: ответ,
    /// начатый при прежних настройках, не применяется вовсе — сузить его можно,
    /// но он держит «устаревший результат не возвращает safe» структурно,
    /// а не рассуждением, и он же единственный источник
    /// `discardedSettingsChanged` в общей схеме выгрузки. Отпечаток выхода: путь
    /// сменился, пока проба летела, — её ответ описывает уже не нас. Оба
    /// отброшенных ответа остаются в журнале проверок: запрос состоялся,
    /// и молчать о нём нельзя.
    fn apply_probe(
        &self,
        report: GeoProbeReport,
        expected_revision: u64,
        expected_fingerprint: String,
        trigger: CheckTrigger,
        milliseconds: u64,
    ) {
        // Охрана остановлена: применять ответ некуда и незачем — цели уже
        // продолжены, а такта, который разобрал бы последствия, больше не будет.
        if self.is_shut_down() {
            return;
        }

        let settings = self.settings.settings();
        if settings.revision != expected_revision {
            self.note_check(
                trigger,
                CheckOutcome::DiscardedSettingsChanged,
                &report.outcome(),
                &report,
                &expected_fingerprint,
                milliseconds,
            );
            return;
        }

        let network = self.network.snapshot();
        let fingerprint = network.verdict_fingerprint();
        if fingerprint != expected_fingerprint {
            self.note_check(
                trigger,
                CheckOutcome::DiscardedPathChanged,
                &report.outcome(),
                &report,
                &expected_fingerprint,
                milliseconds,
            );
            return;
        }

        let outcome = self.admissible_outcome(&report, &fingerprint);
        let result = if matches!(outcome, GeoOutcome::Resolved(_)) {
            CheckOutcome::Answered
        } else {
            CheckOutcome::Failed
        };
        self.note_check(
            trigger,
            result,
            &outcome,
            &report,
            &fingerprint,
            milliseconds,
        );

        {
            let mut inner = self.inner.lock().expect("состояние охраны");
            if let GeoOutcome::Resolved(reading) = &outcome {
                inner.established = Some(Established {
                    reading: reading.clone(),
                    fingerprint: fingerprint.clone(),
                    revision: settings.revision,
                });
                inner.last_reading = Some(reading.clone());
                inner.announced_loss = None;
            }
            if let GeoOutcome::Degraded { previous, .. } = &outcome {
                inner.last_reading = Some(previous.clone());
            }
            inner.verdict = Some((settings.revision, fingerprint.clone()));
            inner.last_report = Some(report.clone());
            inner.last_network = network;
            // Отчёт отдаётся и при отказе: экран обязан показать, кто именно молчал.
            inner.snapshot.report = Some(report);
        }

        // Пока проба летела, целей могло не остаться вовсе: настройки читаются
        // непосредственно перед применением, а не на старте запроса.
        // Проход ответа — такой же проход: обход у него свой и один.
        let scan = self.enforcer.scan(&settings.target_rules());

        let config = settings.guard_config();
        if !settings.is_enabled || !config.has_targets() {
            self.inner.lock().expect("состояние охраны").announced_loss = None;
            self.dispatch(GuardInput::Disarmed, &settings, &scan);
            return;
        }

        let vpn = self.vpn_app_status(&settings, &scan);
        self.feed_verdict(&settings, outcome, vpn, &fingerprint);
        self.enforce(&settings, &scan);
    }

    /// Запущено ли выбранное VPN-приложение.
    ///
    /// Обход `/proc` буквально тот же, что у целей: правило приложения приходит
    /// из настроек уже разрешённым, а в список целей не попадает никогда —
    /// завершать свой источник защиты охрана не имеет права.
    fn vpn_app_status(&self, settings: &Settings, scan: &Scan) -> VpnAppStatus {
        let Some(rule) = settings.vpn_app_rule() else {
            return VpnAppStatus::NotChosen;
        };
        if self.enforcer.is_running_in(&rule, scan) {
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
