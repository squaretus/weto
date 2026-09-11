//! Общее состояние приложения и фоновый цикл охраны.
//!
//! Охрана живёт в отдельном потоке и делится результатом через снимок под
//! мьютексом. UI читает снимок по таймеру главного цикла GTK: событийная
//! рассылка между потоками здесь ничего бы не дала, а стоила бы каналов
//! и лишних состояний.
//!
//! Отдельного демона нет и не будет: на Linux он не нужен ни для прав
//! (их не требуется нигде), ни для резидентности — её обеспечивает автозапуск
//! сессии. Ровно как на macOS, где охрана живёт в процессе приложения.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use weto_config::checks::{CheckEvent, CheckLog};
use weto_config::journal::{GeoReadingPatch, Journal, KillContext, KillEvent, KillEventKind};
use weto_config::paths::Paths;
use weto_config::settings::{Settings, Theme};
use weto_core::episode::EpisodeLedger;
use weto_core::guard_machine::GuardAction;
use weto_core::pause_plan::RecoveredProcess;
use weto_core::process::{MatchBasis, MatchedProcess};
use weto_core::terminal::TerminalHost;
use weto_guard::controller::{
    CheckReporting, GuardController, GuardSnapshot, KillReporting, SettingsProviding,
};
use weto_guard::enforcer::ProcessEnforcer;
use weto_sys::geo_probe::{GeoEndpoints, HttpGeoProbe, RouteNetworkPath};
use weto_sys::network_events::{NetlinkEventSource, NetworkEventSourcing};
use weto_sys::network_snapshot::KernelNetworkReader;
use weto_sys::notifications::{DesktopNotifier, KillNotifying};
use weto_sys::process_registry::{ProcRegistry, ProcessRegistryReading};
use weto_sys::process_signaler::ProcessSignaler;
use weto_sys::secret_store::{FileSecretStore, SecretStoring};
use weto_sys::terminal::{DesktopTerminalActivator, TerminalActivating};

/// Пока небезопасно — 250 мс: терминальные цели больше ничем не поймать.
const TICK_UNSAFE: Duration = Duration::from_millis(250);

/// Штатный тик — раз в секунду и константой, а не настройкой: опрос системы
/// бесплатный, а платит за частоту расписание гео внутри охраны.
const TICK_SAFE: Duration = Duration::from_secs(1);

/// Настройки читаются из файла при каждом обращении охраны — так правка
/// из окна настроек применяется к следующему же тику без всякой рассылки.
pub struct SharedSettings {
    path: std::path::PathBuf,
    cached: Mutex<Settings>,
}

impl SharedSettings {
    pub fn load(paths: &Paths) -> Arc<SharedSettings> {
        let path = paths.settings_file();
        let cached = Settings::load(&path).unwrap_or_default();
        Arc::new(SharedSettings {
            path,
            cached: Mutex::new(cached),
        })
    }

    pub fn current(&self) -> Settings {
        self.cached.lock().expect("настройки").clone()
    }

    /// Правка всегда поднимает ревизию: по ней охрана понимает, что прежний
    /// вердикт больше не свеж.
    pub fn edit(&self, change: impl FnOnce(&mut Settings)) {
        let mut settings = self.cached.lock().expect("настройки");
        change(&mut settings);
        settings.revision += 1;
        if let Err(error) = settings.save(&self.path) {
            eprintln!("weto: настройки не сохранились: {error}");
        }
    }
}

/// Обёртка ради правила сирот: и трейт, и `Arc` объявлены не здесь,
/// поэтому реализовать одно для другого напрямую нельзя.
struct SettingsSource(Arc<SharedSettings>);

impl SettingsProviding for SettingsSource {
    fn settings(&self) -> Settings {
        self.0.current()
    }
}

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
struct JournalWriter {
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
    pause: Option<String>,
    recovery: Option<String>,
}

impl PauseEpisodes {
    fn open(&self) -> Vec<String> {
        [self.pause.clone(), self.recovery.clone()]
            .into_iter()
            .flatten()
            .collect()
    }
}

impl JournalWriter {
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
    /// с прошлого запуска момент из учёта.
    fn pause_events(
        episode_id: &str,
        stopped: &[MatchedProcess],
        context: &KillContext,
        at: impl Fn(usize) -> std::time::SystemTime,
    ) -> Vec<KillEvent> {
        stopped
            .iter()
            .enumerate()
            .map(|(order, process)| KillEvent {
                id: format!("{episode_id}-{order}"),
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
        let episode_id = {
            let mut episodes = self.pause_episodes.lock().expect("эпизоды стояния");
            episodes.pause.get_or_insert_with(new_id).clone()
        };
        let events = Self::pause_events(&episode_id, stopped, context, |_| {
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
        let episode_id = {
            let mut episodes = self.pause_episodes.lock().expect("эпизоды стояния");
            episodes.recovery.get_or_insert_with(new_id).clone()
        };
        let processes: Vec<MatchedProcess> = standing
            .iter()
            .map(|recovered| recovered.process.clone())
            .collect();
        // Дата записи — когда процесс встал, а не когда weto это заметил.
        let events = Self::pause_events(&episode_id, &processes, context, |order| {
            standing[order].stopped_at
        });

        let mut journal = self.journal.lock().expect("журнал");
        journal.append(events);
        self.save(&journal);
    }

    /// Чем стояние кончилось. Дописывается обоим эпизодам сразу, а запись шелла
    /// получает свой исход, если он расходится с исходом цели.
    fn pause_resolved(&self, outcome: &str, shell_outcome: Option<&str>, context: &KillContext) {
        let episodes = {
            let mut episodes = self.pause_episodes.lock().expect("эпизоды стояния");
            let open = episodes.open();
            episodes.pause = None;
            episodes.recovery = None;
            open
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
            );
            if let Some(shell_outcome) = shell_outcome {
                journal.refine_basis(&episode_id, MatchBasis::Shell, shell_outcome);
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
            self.notifier
                .notify(&Self::targets_summary(killed), &context.reason);
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
struct CheckWriter {
    paths: Paths,
    log: Arc<Mutex<CheckLog>>,
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

pub struct AppState {
    pub paths: Paths,
    pub settings: Arc<SharedSettings>,
    controller: Arc<GuardController>,
    journal: Arc<Mutex<Journal>>,
    /// Журнал проверок — рядом с журналом завершений и отдельным файлом.
    checks: Arc<Mutex<CheckLog>>,
    /// Проба в полёте. На месте кнопки проверки крутится индикатор, а повторное
    /// нажатие запроса не порождает: у подтверждающего сервиса лимит.
    probing: Arc<AtomicBool>,
    /// Кто поднимет терминал цели, ушедшей в фон под паузой, и чем.
    terminal: Box<dyn TerminalActivating>,
    /// Свой обход `/proc` для интерфейса: охрана свой снимок наружу не отдаёт,
    /// а обход стоит пару миллисекунд и случается только у стоящей цели.
    registry: Box<dyn ProcessRegistryReading>,
    /// Нажатия на уведомление. Поток уведомлений кладёт сюда просьбу показать
    /// окно, главный цикл забирает её своим тактом: окна из чужого потока
    /// не открывают.
    open_requests: Mutex<std::sync::mpsc::Receiver<()>>,
}

impl AppState {
    pub fn new(paths: Paths) -> Arc<AppState> {
        let settings = SharedSettings::load(&paths);
        let journal = Arc::new(Mutex::new(Journal::load(&paths.journal_file())));
        let checks = Arc::new(Mutex::new(CheckLog::load(&paths.checks_file())));

        // Нажатие на уведомление открывает окно статуса — то же самое делает
        // тап по уведомлению на macOS. Обработчик ставится один раз на старте
        // и больше не меняется.
        let (open_sender, open_requests) = std::sync::mpsc::channel();
        let open_sender = Mutex::new(open_sender);
        let notifier = DesktopNotifier::with_open_handler(Arc::new(move || {
            if let Ok(sender) = open_sender.lock() {
                let _ = sender.send(());
            }
        }));

        let writer = JournalWriter {
            paths: paths.clone(),
            journal: journal.clone(),
            episode: Mutex::new(EpisodeLedger::new()),
            pause_episodes: Mutex::new(PauseEpisodes::default()),
            notifier: Box::new(notifier),
        };

        let controller = Arc::new(GuardController::new(
            Box::new(KernelNetworkReader::new()),
            Box::new(HttpGeoProbe::new(
                GeoEndpoints::default(),
                Box::new(RouteNetworkPath),
            )),
            Box::new(FileSecretStore::new(paths.token_file())),
            Box::new(SettingsSource(settings.clone())),
            ProcessEnforcer::new(
                Box::new(ProcRegistry::new()),
                Box::new(ProcessSignaler::new()),
                paths.stopped_file(),
            ),
            Box::new(writer),
            Box::new(CheckWriter {
                paths: paths.clone(),
                log: checks.clone(),
            }),
        ));

        Arc::new(AppState {
            paths,
            settings,
            controller,
            journal,
            checks,
            probing: Arc::new(AtomicBool::new(false)),
            terminal: Box::new(DesktopTerminalActivator::new()),
            registry: Box::new(ProcRegistry::new()),
            open_requests: Mutex::new(open_requests),
        })
    }

    pub fn snapshot(&self) -> GuardSnapshot {
        self.controller.snapshot()
    }

    /// Сколько цели ещё могут стоять. `None` — не стоят. Строка «что дальше»
    /// в объяснении статуса читает часы отсюда, а не сама.
    pub fn remaining_pause(&self) -> Option<Duration> {
        self.controller.remaining_pause()
    }

    /// Кто держит терминал стоящей цели и можно ли его поднять.
    ///
    /// Ответ спрашивается на живом снимке `/proc` и на живой шине, поэтому
    /// интерфейс держит его в кэше: пока цель стоит, терминала она не меняет.
    pub fn terminal_for(&self, pid: i32) -> Option<TerminalHost> {
        self.terminal.locate(pid, &self.registry.snapshot())
    }

    /// Показать пользователю терминал стоящей цели: под паузой процесс
    /// не отвечает, и найти его окно самому — задача не для человека.
    /// Порт macOS `GuardVM.showTerminal(for:)`.
    pub fn show_terminal(&self, pid: i32) -> bool {
        match self.terminal_for(pid) {
            Some(host) => self.terminal.activate(&host),
            None => false,
        }
    }

    /// Просил ли пользователь показать окно нажатием на уведомление.
    /// Копятся они по одному вопросу, поэтому очередь вычерпывается разом.
    pub fn take_open_request(&self) -> bool {
        let Ok(requests) = self.open_requests.lock() else {
            return false;
        };
        let mut asked = false;
        while requests.try_recv().is_ok() {
            asked = true;
        }
        asked
    }

    pub fn journal(&self) -> Journal {
        self.journal.lock().expect("журнал").clone()
    }

    /// Журнал для разбора: события вместе с настройками момента и версиями.
    ///
    /// Токен в файл не попадает — только признак, задан ли он: без этого
    /// отказ ipinfo в трассах не объяснить.
    pub fn export_journal(&self) -> Option<String> {
        let settings = self.settings.current();
        // Токен спрашивается у хранилища, а в файл уходит только признак:
        // выгрузка отправляется в переписку.
        let has_token = FileSecretStore::new(self.paths.token_file())
            .load()
            .ok()
            .flatten()
            .is_some_and(|token| !token.is_empty());
        let events = self.journal().entries().to_vec();
        let checks = self
            .checks
            .lock()
            .expect("журнал проверок")
            .entries()
            .to_vec();

        let export = weto_config::export::JournalExport::build(
            &settings,
            events,
            checks,
            has_token,
            std::time::SystemTime::now(),
            os_version(),
        );
        match export.encoded() {
            Ok(text) => Some(text),
            Err(error) => {
                eprintln!("weto: журнал не собрался: {error}");
                None
            }
        }
    }

    /// Очистка журнала — и в памяти, и на диске: иначе записи вернулись бы
    /// при следующем чтении файла.
    pub fn clear_journal(&self) {
        let mut journal = self.journal.lock().expect("журнал");
        journal.clear();
        if let Err(error) = journal.save(&self.paths.journal_file()) {
            eprintln!("weto: журнал не очистился: {error}");
        }
    }

    pub fn reload_journal(&self) {
        let fresh = Journal::load(&self.paths.journal_file());
        *self.journal.lock().expect("журнал") = fresh;
    }

    pub fn theme(&self) -> Theme {
        self.settings.current().theme
    }

    pub fn is_probing(&self) -> bool {
        self.probing.load(Ordering::Relaxed)
    }

    /// Проверка по кнопке уходит на рабочий поток: HTTP блокирующий,
    /// а главный поток занят отрисовкой. Повторное нажатие в полёте запроса
    /// не порождает — у подтверждающего сервиса лимит.
    pub fn probe_now(&self) {
        if self.probing.swap(true, Ordering::SeqCst) {
            return;
        }
        let controller = self.controller.clone();
        let probing = self.probing.clone();
        std::thread::spawn(move || {
            controller.probe_now();
            probing.store(false, Ordering::SeqCst);
        });
    }

    /// Штатный выход: замороженных целей не оставляем.
    ///
    /// Наблюдать последствия SIGCONT уже нечем — такта больше не будет, — поэтому
    /// запись, которую сигнал не разрешил, остаётся в учёте и достаётся
    /// восстановлению при следующем запуске, а журнал пишет «не подтверждено»,
    /// а не «возобновлено».
    pub fn shutdown(&self) {
        self.controller.shutdown();
    }

    /// Охрана стартует при запуске процесса, а не при первом открытии окна.
    ///
    /// На macOS это правило появилось потому, что `MenuBarExtra` создаёт
    /// содержимое лениво и защиты не было бы, пока пользователь не откроет меню.
    /// Здесь та же ловушка ждала бы с окном, которое может не открыться никогда.
    pub fn start_guard(self: &Arc<Self>) {
        let controller = self.controller.clone();
        std::thread::Builder::new()
            .name("weto-guard".to_string())
            .spawn(move || {
                // После падения: SIGCONT всем из учёта, кто ещё стоит и остался
                // тем же процессом. Раньше первого такта — обязательство «вернуть
                // из паузы» не зависит ни от вердикта, ни от наличия целей.
                controller.recover_stopped();
                let events = NetlinkEventSource.subscribe();
                loop {
                    let phase = controller.tick();
                    // Шаг штатного тика перечитывается каждый раз: правка
                    // в настройках применяется со следующего же круга. Чаще —
                    // пока цели не работают: терминальную цель, родившуюся под
                    // паузой или запретом, больше ничем не поймать.
                    let interval = match phase.action() {
                        GuardAction::Run => TICK_SAFE,
                        GuardAction::Pause | GuardAction::Terminate => TICK_UNSAFE,
                    };
                    // Событие сети прерывает ожидание: реакция на падение
                    // туннеля не должна ждать конца интервала.
                    match events.recv_timeout(interval) {
                        Ok(()) | Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                            std::thread::sleep(interval)
                        }
                    }
                }
            })
            .expect("поток охраны не создался");
    }
}

/// Версия ядра для выгрузки. Из `/proc/version` — в контейнере и на живой машине
/// это единственный источник, не требующий ни утилит, ни зависимостей.
fn os_version() -> String {
    std::fs::read_to_string("/proc/version")
        .map(|text| text.trim().to_string())
        .unwrap_or_else(|_| "неизвестно".to_string())
}
