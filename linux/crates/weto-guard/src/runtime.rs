//! Цикл охраны и писатели её журналов — общие для приложения с окном
//! и терминальной версии.
//!
//! Жили в `weto-app/src/state.rs`, то есть в GTK-крейте, и терминальной версии
//! без GTK взять их было неоткуда. Перенесены без изменения поведения: тот же
//! журнал, те же эпизоды, тот же такт. Что разное у двух оболочек — уведомитель
//! (`KillNotifying`) и то, что делается после каждого прохода, — приходит снаружи.
//!
//! Охрана живёт в отдельном потоке и делится результатом через снимок под
//! мьютексом. Отдельного демона нет и не будет: на Linux он не нужен ни для прав
//! (их не требуется нигде), ни для резидентности — её обеспечивает автозапуск
//! сессии или сервис systemd. Ровно как на macOS, где охрана живёт в процессе
//! приложения.

use std::collections::{HashMap, HashSet};
use std::sync::mpsc::RecvTimeoutError;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use weto_config::checks::{CheckEvent, CheckLog};
use weto_config::journal::{GeoReadingPatch, Journal, KillContext, KillEvent, KillEventKind};
use weto_config::paths::Paths;
use weto_core::episode::EpisodeLedger;
use weto_core::guard_machine::{GuardAction, GuardPhase};
use weto_core::pause_plan::RecoveredProcess;
use weto_core::process::{MatchBasis, MatchedProcess};
use weto_sys::geo_probe::{GeoEndpoints, HttpGeoProbe, RouteNetworkPath};
use weto_sys::network_events::NetworkEventSourcing;
use weto_sys::network_snapshot::KernelNetworkReader;
use weto_sys::notifications::KillNotifying;
use weto_sys::process_registry::ProcRegistry;
use weto_sys::process_signaler::ProcessSignaler;
use weto_sys::secret_store::FileSecretStore;

use crate::controller::{
    CheckReporting, GuardController, KillReporting, OutcomeException, SettingsProviding,
};
use crate::enforcer::ProcessEnforcer;

/// Пока небезопасно — 250 мс: терминальные цели больше ничем не поймать.
pub const TICK_UNSAFE: Duration = Duration::from_millis(250);

/// Штатный тик — раз в секунду и константой, а не настройкой: опрос системы
/// бесплатный, а платит за частоту расписание гео внутри охраны.
pub const TICK_SAFE: Duration = Duration::from_secs(1);

/// Журнал пишет каждый завершённый процесс отдельно.
///
/// Дедупликация по паре «причина + pid»: тот же процесс по той же причине второй
/// записи не заводит, а запущенный заново — заводит всегда. Дедупликация по одной
/// лишь причине, как было, вообще не пускала в журнал цель, запущенную посреди
/// эпизода: пользователь видел завершение, которого журнал не помнил.
///
/// «Подключение ещё не проверено» приходит первым, потому что fail-closed
/// срабатывает раньше вердикта, и уточняется на месте. Эпизод, закончившийся
/// безопасным выходом, дописывает исход: без него запись навсегда оставалась
/// с отговоркой, и завершение выглядело беспричинным.
pub struct JournalWriter {
    paths: Paths,
    /// Тот же самый журнал, что показывает окно настроек.
    ///
    /// Копий было две — своя у писателя и своя у состояния приложения, — и они
    /// не сходились никогда: новые завершения в окне не появлялись вовсе,
    /// а «очистить журнал» стирало только показанную копию, после чего первая
    /// же запись возвращала на диск всё стёртое.
    journal: Arc<Mutex<Journal>>,
    episode: Mutex<EpisodeLedger>,
    /// Эпизоды стояния: паузы и восстановления после падения. Исход дописывается
    /// обоим сразу — стоящее с прошлой жизни и остановленное сейчас кончается
    /// одним и тем же.
    pause_episodes: Mutex<PauseEpisodes>,
    notifier: Box<dyn KillNotifying>,
}

#[derive(Default)]
struct PauseEpisodes {
    pause: Option<StandingEpisode>,
    recovery: Option<StandingEpisode>,
    /// pid, получившие свой исход раньше эпизода: цель сняли с охраны, и процесс
    /// продолжен своим проходом. Общий исход эпизода их записи не переписывает.
    released: HashSet<i32>,
}

impl PauseEpisodes {
    fn open(&self) -> Vec<String> {
        [
            self.pause.as_ref().map(|episode| episode.id.clone()),
            self.recovery.as_ref().map(|episode| episode.id.clone()),
        ]
        .into_iter()
        .flatten()
        .collect()
    }
}

/// Открытый эпизод стояния: идентификатор и счётчик уже выданных записей.
///
/// Счётчик продолжается внутри эпизода, а не начинается заново на каждом
/// проходе: цель, попавшая в ту же паузу вторым заходом — родившаяся под ней
/// или продолженная и остановленная снова, — получала бы `{эпизод}-0` во второй
/// раз, и две разные записи журнала оказывались бы неразличимы по `id`.
/// На macOS у записи свой UUID, а `id` — часть общего формата выгрузки.
struct StandingEpisode {
    id: String,
    next: usize,
}

impl StandingEpisode {
    fn new() -> StandingEpisode {
        StandingEpisode {
            id: new_id(),
            next: 0,
        }
    }

    /// Номер первой из `count` записей; счётчик сдвигается на все сразу.
    fn take(&mut self, count: usize) -> usize {
        let first = self.next;
        self.next += count;
        first
    }
}

impl JournalWriter {
    /// Писатель над общим журналом: тот же `Arc`, что читает экран или команда
    /// `journal`. Уведомитель — снаружи: приложению рабочий стол, терминальной
    /// версии строка в лог.
    pub fn new(
        paths: Paths,
        journal: Arc<Mutex<Journal>>,
        notifier: Box<dyn KillNotifying>,
    ) -> JournalWriter {
        JournalWriter {
            paths,
            journal,
            episode: Mutex::new(EpisodeLedger::new()),
            pause_episodes: Mutex::new(PauseEpisodes::default()),
            notifier,
        }
    }

    fn save(&self, journal: &Journal) {
        if let Err(error) = journal.save(&self.paths.journal_file()) {
            eprintln!("weto: журнал не сохранился: {error}");
        }
    }

    fn patch(context: &KillContext) -> GeoReadingPatch {
        context.reading.clone()
    }

    /// Записи стояния: по записи на процесс, `kind: paused`, эпизод один.
    /// Момент приходит функцией — у паузы это «сейчас», у восстановления
    /// с прошлого запуска момент из учёта. Нумерация продолжается с `first`:
    /// эпизод один на всё стояние, а проходов внутри него бывает несколько.
    fn pause_events(
        episode_id: &str,
        first: usize,
        stopped: &[MatchedProcess],
        context: &KillContext,
        at: impl Fn(usize) -> std::time::SystemTime,
    ) -> Vec<KillEvent> {
        stopped
            .iter()
            .enumerate()
            .map(|(order, process)| KillEvent {
                id: format!("{episode_id}-{}", first + order),
                episode_id: episode_id.to_string(),
                at: at(order),
                target_name: process.target_name.clone(),
                pid: process.pid,
                parent_pid: process.parent_pid,
                executable_path: process.executable_path.clone(),
                matched_by: process.matched_by,
                kind: KillEventKind::Paused,
                reason_text: context.reason.clone(),
                resolution_text: None,
                ip: context.reading.ip.clone(),
                country: context.reading.country.clone(),
                confirmed_country: context.reading.confirmed_country.clone(),
                confirm_source: context.reading.confirm_source.clone(),
                diagnostics: Some(context.diagnostics.clone()),
            })
            .collect()
    }

    /// «claude ×34, codex» — цели прохода с числом завершённых процессов там,
    /// где их больше одного.
    fn targets_summary(killed: &[MatchedProcess]) -> Vec<String> {
        let mut order: Vec<String> = Vec::new();
        let mut counts: HashMap<String, usize> = HashMap::new();
        for process in killed {
            if !counts.contains_key(&process.target_name) {
                order.push(process.target_name.clone());
            }
            *counts.entry(process.target_name.clone()).or_default() += 1;
        }
        order
            .into_iter()
            .map(|name| match counts.get(&name) {
                Some(1) | None => name,
                Some(count) => format!("{name} ×{count}"),
            })
            .collect()
    }
}

impl KillReporting for JournalWriter {
    /// Цели снова работают: учёт «что уже описано» обнуляется — без этого
    /// следующее падение по той же причине писалось бы «запуск запрещён»
    /// вместо «завершено».
    fn episode_finished(&self, _context: &KillContext) {
        self.episode.lock().expect("журнал").finish();
    }

    /// Процессы, которым ушёл SIGSTOP. Эпизод один на всё стояние: цели, их
    /// потомки и шелл, вошедший в план ради терминала цели, объясняются вместе
    /// и получают один исход.
    fn paused(&self, stopped: &[MatchedProcess], context: &KillContext) {
        if stopped.is_empty() {
            return;
        }
        let (episode_id, first) = {
            let mut episodes = self.pause_episodes.lock().expect("эпизоды стояния");
            let episode = episodes.pause.get_or_insert_with(StandingEpisode::new);
            (episode.id.clone(), episode.take(stopped.len()))
        };
        let events = Self::pause_events(&episode_id, first, stopped, context, |_| {
            std::time::SystemTime::now()
        });

        let mut journal = self.journal.lock().expect("журнал");
        journal.append(events);
        self.save(&journal);
    }

    /// Процессы, застигнутые стоящими на старте. Эпизод свой: пробы за этим
    /// стоянием нет, и причина говорит это прямо.
    fn recovered(&self, standing: &[RecoveredProcess], context: &KillContext) {
        if standing.is_empty() {
            return;
        }
        let (episode_id, first) = {
            let mut episodes = self.pause_episodes.lock().expect("эпизоды стояния");
            let episode = episodes.recovery.get_or_insert_with(StandingEpisode::new);
            (episode.id.clone(), episode.take(standing.len()))
        };
        let processes: Vec<MatchedProcess> = standing
            .iter()
            .map(|recovered| recovered.process.clone())
            .collect();
        // Дата записи — когда процесс встал, а не когда weto это заметил.
        let events = Self::pause_events(&episode_id, first, &processes, context, |order| {
            standing[order].stopped_at
        });

        let mut journal = self.journal.lock().expect("журнал");
        journal.append(events);
        self.save(&journal);
    }

    /// Записи, отпущенные снятием цели с охраны: исход у них свой и приходит он
    /// раньше эпизодного. Запоминаются здесь же — общий исход эпизода их не трогает.
    fn released(&self, pids: &[i32], outcome: &str, _context: &KillContext) {
        if pids.is_empty() {
            return;
        }
        let (episodes, freed) = {
            let mut episodes = self.pause_episodes.lock().expect("эпизоды стояния");
            episodes.released.extend(pids.iter().copied());
            (
                episodes.open(),
                pids.iter().copied().collect::<HashSet<i32>>(),
            )
        };
        if episodes.is_empty() {
            return;
        }

        let mut journal = self.journal.lock().expect("журнал");
        let mut touched = false;
        for episode_id in episodes {
            touched |= journal.refine_pids(&episode_id, &freed, outcome);
        }
        if touched {
            self.save(&journal);
        }
    }

    /// Чем стояние кончилось. Дописывается обоим эпизодам сразу, а запись шелла
    /// получает свой исход, если он расходится с исходом цели.
    fn pause_resolved(
        &self,
        outcome: &str,
        shell_outcome: Option<&str>,
        exceptions: &[OutcomeException],
        context: &KillContext,
    ) {
        let (episodes, released) = {
            let mut episodes = self.pause_episodes.lock().expect("эпизоды стояния");
            let open = episodes.open();
            episodes.pause = None;
            episodes.recovery = None;
            (open, std::mem::take(&mut episodes.released))
        };
        if episodes.is_empty() {
            return;
        }

        let mut journal = self.journal.lock().expect("журнал");
        let mut touched = false;
        for episode_id in episodes {
            touched |= journal.refine_episode(
                &episode_id,
                None,
                Some(outcome),
                Some(&Self::patch(context)),
                Some(&context.diagnostics),
                &released,
            );
            if let Some(shell_outcome) = shell_outcome {
                journal.refine_basis(&episode_id, MatchBasis::Shell, shell_outcome, &released);
            }
            for exception in exceptions {
                let pids: HashSet<i32> = exception.pids.difference(&released).copied().collect();
                journal.refine_pids(&episode_id, &pids, &exception.text);
            }
        }
        if touched {
            self.save(&journal);
        }
    }

    fn report(
        &self,
        killed: &[MatchedProcess],
        recordable: &[MatchedProcess],
        context: &KillContext,
    ) {
        let mut episode = self.episode.lock().expect("журнал");

        let is_new_reason = episode.is_new_reason(&context.reason);
        let fresh: Vec<MatchedProcess> = episode
            .fresh(recordable, &context.reason, |process| process.pid)
            .into_iter()
            .cloned()
            .collect();

        // Причина и завершённые pid запоминаются независимо от записи: иначе
        // такт раз в 250 мс повторял бы и уведомление, и записи про уже мёртвые
        // процессы.
        let announce = !killed.is_empty() && (is_new_reason || !fresh.is_empty());
        episode.remember(&context.reason, killed.iter().map(|process| process.pid));
        drop(episode);

        // Уведомление — на проход, а не на процесс: тридцать четыре баннера
        // подряд не сообщение, а помеха. Настройки «уведомлять или нет»
        // нет и на macOS. Считаются завершённые сейчас, а не все совпавшие:
        // иначе один добитый процесс давал бы баннер «claude ×34». Цель, стоявшая
        // до завершения, входит сюда наравне: запись о ней уже есть, но новость
        // «цели завершены» от этого не исчезает.
        if announce {
            self.notifier.notify(
                &Self::targets_summary(killed),
                &context.reason,
                killed.len(),
            );
        }

        if fresh.is_empty() {
            return;
        }

        let kind = if is_new_reason {
            KillEventKind::Terminated
        } else {
            KillEventKind::LaunchBlocked
        };

        // Один проход охраны — один эпизод: сколько процессов завершено,
        // столько и записей, и все они помнят, что это было одно событие.
        let episode_id = new_id();
        let at = std::time::SystemTime::now();
        let events: Vec<KillEvent> = fresh
            .iter()
            .enumerate()
            .map(|(order, process)| KillEvent {
                id: format!("{episode_id}-{order}"),
                episode_id: episode_id.clone(),
                at,
                target_name: process.target_name.clone(),
                pid: process.pid,
                parent_pid: process.parent_pid,
                executable_path: process.executable_path.clone(),
                matched_by: process.matched_by,
                kind,
                reason_text: context.reason.clone(),
                resolution_text: None,
                ip: context.reading.ip.clone(),
                country: context.reading.country.clone(),
                confirmed_country: context.reading.confirmed_country.clone(),
                confirm_source: context.reading.confirm_source.clone(),
                diagnostics: Some(context.diagnostics.clone()),
            })
            .collect();

        let mut journal = self.journal.lock().expect("журнал");
        journal.append(events);
        self.save(&journal);
    }

    /// Терминальная цель под паузой потеряла терминал: сообщаем тем же путём,
    /// что и о завершении.
    fn backgrounded(&self, target_name: &str) {
        self.notifier.notify_backgrounded(target_name);
    }
}

/// Журнал проверок приложения: пишется сразу на диск, как и журнал завершений,
/// и в интерфейс не попадает — это материал выгрузки.
pub struct CheckWriter {
    paths: Paths,
    log: Arc<Mutex<CheckLog>>,
}

impl CheckWriter {
    pub fn new(paths: Paths, log: Arc<Mutex<CheckLog>>) -> CheckWriter {
        CheckWriter { paths, log }
    }
}

impl CheckReporting for CheckWriter {
    fn record(&self, event: CheckEvent) {
        let mut log = self.log.lock().expect("журнал проверок");
        if !log.append(event) {
            return;
        }
        if let Err(error) = log.save(&self.paths.checks_file()) {
            eprintln!("weto: журнал проверок не сохранился: {error}");
        }
    }
}

/// Идентификатор эпизода. UUID сюда тянуть незачем: хватает монотонного счётчика
/// с отметкой запуска — записи живут внутри одного файла одного пользователя.
fn new_id() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let order = COUNTER.fetch_add(1, Ordering::Relaxed);
    let since_epoch = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or_default();
    format!("{since_epoch:x}-{order:x}")
}

/// Охрана на настоящих границах: ядро, `/proc`, сигналы, гео-сервисы, токен
/// и учёт остановленных по путям установки. Разное у двух оболочек — откуда
/// настройки и куда уходят журналы — приходит параметрами.
pub fn system_controller(
    paths: &Paths,
    settings: Box<dyn SettingsProviding>,
    reporter: Box<dyn KillReporting>,
    checks: Box<dyn CheckReporting>,
) -> GuardController {
    GuardController::new(
        Box::new(KernelNetworkReader::new()),
        Box::new(HttpGeoProbe::new(
            GeoEndpoints::default(),
            Box::new(RouteNetworkPath),
        )),
        Box::new(FileSecretStore::new(paths.token_file())),
        settings,
        ProcessEnforcer::new(
            Box::new(ProcRegistry::new()),
            Box::new(ProcessSignaler::new()),
            paths.stopped_file(),
        ),
        reporter,
        checks,
    )
}

/// Шаг такта по фазе: чаще — пока цели не работают, терминальную цель,
/// родившуюся под паузой или запретом, больше ничем не поймать.
pub fn tick_interval(phase: &GuardPhase) -> Duration {
    match phase.action() {
        GuardAction::Run => TICK_SAFE,
        GuardAction::Pause | GuardAction::Terminate => TICK_UNSAFE,
    }
}

/// Тело потока охраны: восстановление после падения, затем такты до штатного
/// выхода. `after_pass` получает фазу каждого такта — приложению он не нужен,
/// терминальная версия пишет по нему файл статуса и лог.
pub fn run_guard(
    controller: &Arc<GuardController>,
    events: &dyn NetworkEventSourcing,
    mut after_pass: impl FnMut(&GuardPhase),
) {
    // После падения: SIGCONT всем из учёта, кто ещё стоит и остался
    // тем же процессом. Раньше первого такта — обязательство «вернуть
    // из паузы» не зависит ни от вердикта, ни от наличия целей.
    controller.recover_stopped();
    let events = events.subscribe();
    loop {
        // Штатный выход уже прошёл: цели продолжены, и такту здесь
        // делать нечего. Пустым тактом поток не крутится — он
        // кончается вместе с охраной.
        if controller.is_shut_down() {
            break;
        }
        let phase = controller.tick();
        after_pass(&phase);
        // Шаг штатного тика перечитывается каждый раз: правка
        // в настройках применяется со следующего же круга. Чаще —
        // пока цели не работают: терминальную цель, родившуюся под
        // паузой или запретом, больше ничем не поймать.
        let interval = tick_interval(&phase);
        // Событие сети прерывает ожидание: реакция на падение
        // туннеля не должна ждать конца интервала.
        match events.recv_timeout(interval) {
            Ok(()) | Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => std::thread::sleep(interval),
        }
    }
}

/// Охрана в своём потоке. Стартует при запуске процесса, а не при первом
/// открытии окна: на macOS это правило появилось потому, что `MenuBarExtra`
/// создаёт содержимое лениво, и здесь та же ловушка ждала бы с окном, которое
/// может не открыться никогда.
pub fn spawn_guard(
    controller: Arc<GuardController>,
    events: Box<dyn NetworkEventSourcing>,
    after_pass: impl FnMut(&GuardPhase) + Send + 'static,
) -> std::thread::JoinHandle<()> {
    std::thread::Builder::new()
        .name("weto-guard".to_string())
        .spawn(move || run_guard(&controller, events.as_ref(), after_pass))
        .expect("поток охраны не создался")
}

/// Версия ядра для выгрузки. Из `/proc/version` — в контейнере и на живой машине
/// это единственный источник, не требующий ни утилит, ни зависимостей.
pub fn os_version() -> String {
    std::fs::read_to_string("/proc/version")
        .map(|text| text.trim().to_string())
        .unwrap_or_else(|_| "неизвестно".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn process(pid: i32) -> MatchedProcess {
        MatchedProcess {
            pid,
            target_name: "claude".to_string(),
            target_entry: "claude".to_string(),
            parent_pid: 1,
            executable_path: "/usr/bin/claude".to_string(),
            matched_by: MatchBasis::Rule,
        }
    }

    /// `id` записи — ключ, которым разбор выгрузки отличает одну запись от другой.
    /// Эпизод стояния живёт всё стояние, и проходов внутри него бывает несколько:
    /// цель, родившаяся под паузой, встаёт вторым проходом того же эпизода —
    /// и до этой правки получала `{эпизод}-0` во второй раз.
    #[test]
    fn a_second_pass_of_the_same_episode_does_not_repeat_a_record_id() {
        let mut episode = StandingEpisode::new();
        let context = KillContext::default();

        let first_pass = [process(10), process(11)];
        let first = episode.take(first_pass.len());
        let mut events =
            JournalWriter::pause_events(&episode.id, first, &first_pass, &context, |_| {
                std::time::SystemTime::UNIX_EPOCH
            });

        let second_pass = [process(12)];
        let next = episode.take(second_pass.len());
        events.extend(JournalWriter::pause_events(
            &episode.id,
            next,
            &second_pass,
            &context,
            |_| std::time::SystemTime::UNIX_EPOCH,
        ));

        let ids: Vec<&str> = events.iter().map(|event| event.id.as_str()).collect();
        let unique: std::collections::HashSet<&&str> = ids.iter().collect();
        assert_eq!(unique.len(), ids.len(), "повторившийся id: {ids:?}");
        // Эпизод при этом один: записи объясняются вместе и получают один исход.
        assert!(events.iter().all(|event| event.episode_id == episode.id));
    }

    /// Что уведомление получило: цели, причина, число завершённых процессов.
    type Announced = Arc<Mutex<Vec<(Vec<String>, String, usize)>>>;

    struct RecordingNotifier(Announced);

    impl KillNotifying for RecordingNotifier {
        fn notify(&self, target_names: &[String], reason: &str, killed_count: usize) {
            self.0
                .lock()
                .unwrap()
                .push((target_names.to_vec(), reason.to_string(), killed_count));
        }

        fn notify_backgrounded(&self, _target_name: &str) {}
    }

    fn named(pid: i32, target_name: &str) -> MatchedProcess {
        MatchedProcess {
            target_name: target_name.to_string(),
            ..process(pid)
        }
    }

    /// Уведомление о завершении — как на macOS: цели прохода с числом процессов
    /// там, где их больше одного, и общее число завершённых сейчас. Считаются
    /// все завершённые, включая стоявших на паузе: запись о них уже есть,
    /// а новость «процессы завершены» от этого не исчезает.
    #[test]
    fn the_kill_notification_counts_every_process_killed_by_the_pass() {
        let home = std::env::temp_dir().join(format!(
            "weto-state-notify-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let paths = weto_config::paths::Paths::rooted(home.clone());
        let announced: Announced = Arc::new(Mutex::new(Vec::new()));
        let writer = JournalWriter::new(
            paths.clone(),
            Arc::new(Mutex::new(Journal::load(&paths.journal_file()))),
            Box::new(RecordingNotifier(announced.clone())),
        );
        let context = KillContext {
            reason: "Страна выхода RU в чёрном списке".to_string(),
            ..KillContext::default()
        };

        let killed = [
            named(10, "claude"),
            named(11, "claude"),
            named(12, "codex"),
            named(13, "claude"),
        ];
        // pid 10 уже описан эпизодом паузы: записи не заводит, но в число входит.
        writer.report(&killed, &killed[1..], &context);

        assert_eq!(
            *announced.lock().unwrap(),
            vec![(
                vec!["claude ×3".to_string(), "codex".to_string()],
                "Страна выхода RU в чёрном списке".to_string(),
                4,
            )]
        );
        let _ = std::fs::remove_dir_all(home);
    }

    /// У разных эпизодов — разные идентификаторы, и счётчик записей у каждого свой:
    /// стояние с прошлого запуска и пауза этого живут рядом.
    #[test]
    fn two_episodes_number_their_records_independently() {
        let mut pause = StandingEpisode::new();
        let mut recovery = StandingEpisode::new();

        assert_ne!(pause.id, recovery.id);
        assert_eq!(pause.take(2), 0);
        assert_eq!(recovery.take(1), 0);
        assert_eq!(pause.take(1), 2);
    }
}
