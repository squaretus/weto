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

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use weto_config::journal::{
    GeoReadingPatch, Journal, KillContext, KillEvent, KillEventKind,
};
use weto_config::paths::Paths;
use weto_config::settings::{Settings, Theme};
use weto_core::geo::SourceOutcome;
use weto_core::policy::{GuardDecision, UnsafeReason};
use weto_core::presentation::GuardState;
use weto_core::process::MatchedProcess;
use weto_guard::controller::{GuardController, GuardSnapshot, KillReporting, SettingsProviding};
use weto_guard::enforcer::ProcessEnforcer;
use weto_sys::geo_probe::{GeoEndpoints, HttpGeoProbe, RouteNetworkPath};
use weto_sys::network_events::{NetlinkEventSource, NetworkEventSourcing};
use weto_sys::network_snapshot::KernelNetworkReader;
use weto_sys::notifications::{KillNotifying, PortalNotifier};
use weto_sys::process_killer::SigtermKiller;
use weto_sys::process_registry::ProcRegistry;
use weto_sys::secret_store::{FileSecretStore, SecretStoring};

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
    episode: Mutex<Episode>,
    notifier: Box<dyn KillNotifying>,
}

#[derive(Default)]
struct Episode {
    /// Пары «причина + pid», уже описанные в журнале.
    recorded: HashSet<(String, i32)>,
    /// Причины, уже описанные в рамках текущего эпизода.
    reasons: HashSet<String>,
    /// Эпизод, записанный до вердикта: его причину предстоит уточнить.
    pending_id: Option<String>,
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
    /// Причина эпизода, ставшая известной, дописывается всем его записям.
    fn refine(&self, context: &KillContext) {
        if context.is_pending {
            return;
        }

        let mut episode = self.episode.lock().expect("журнал");
        let Some(pending_id) = episode.pending_id.take() else {
            return;
        };

        let pending = UnsafeReason::VerificationPending.display_text();
        episode.reasons.remove(&pending);
        episode.reasons.insert(context.reason.clone());

        // Ключ дедупликации переезжает вместе с текстом: те же процессы того же
        // эпизода под уточнённой причиной выглядели бы новыми и завели бы второй
        // набор записей про то же самое падение.
        episode.recorded = episode
            .recorded
            .drain()
            .map(|(reason, pid)| {
                if reason == pending {
                    (context.reason.clone(), pid)
                } else {
                    (reason, pid)
                }
            })
            .collect();
        drop(episode);

        let mut journal = self.journal.lock().expect("журнал");
        if !journal.refine_episode(
            &pending_id,
            Some(&context.reason),
            None,
            Some(&Self::patch(context)),
            Some(&context.diagnostics),
        ) {
            return;
        }
        self.save(&journal);
    }

    /// Эпизод, начавшийся до вердикта, закончился безопасным выходом.
    fn resolved_safe(&self, context: &KillContext) {
        let mut episode = self.episode.lock().expect("журнал");
        let pending_id = episode.pending_id.take();
        episode.recorded.clear();
        episode.reasons.clear();
        drop(episode);

        let Some(pending_id) = pending_id else {
            return;
        };

        let outcome = match (&context.reading.ip, &context.reading.country) {
            (Some(ip), Some(country)) => {
                format!("проверка завершилась безопасным выходом: {ip}, {country}")
            }
            _ => "проверка завершилась безопасным выходом".to_string(),
        };

        let mut journal = self.journal.lock().expect("журнал");
        if !journal.refine_episode(
            &pending_id,
            None,
            Some(&outcome),
            Some(&Self::patch(context)),
            Some(&context.diagnostics),
        ) {
            return;
        }
        self.save(&journal);
    }

    fn report(&self, killed: &[MatchedProcess], context: &KillContext) {
        let mut episode = self.episode.lock().expect("журнал");

        let is_new_reason = !episode.reasons.contains(&context.reason);
        let fresh: Vec<&MatchedProcess> = killed
            .iter()
            .filter(|process| {
                !episode
                    .recorded
                    .contains(&(context.reason.clone(), process.pid))
            })
            .collect();

        if fresh.is_empty() {
            return;
        }

        episode.reasons.insert(context.reason.clone());
        for process in &fresh {
            episode
                .recorded
                .insert((context.reason.clone(), process.pid));
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
                is_descendant: process.is_descendant,
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

        if context.is_pending {
            episode.pending_id = Some(episode_id.clone());
        }
        drop(episode);

        // Уведомление — на проход, а не на процесс: тридцать четыре баннера
        // подряд не сообщение, а помеха. Настройки «уведомлять или нет»
        // нет и на macOS.
        self.notifier
            .notify(&Self::targets_summary(killed), &context.reason);

        let mut journal = self.journal.lock().expect("журнал");
        journal.append(events);
        self.save(&journal);
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
    /// Проба в полёте. На месте кнопки проверки крутится индикатор, а повторное
    /// нажатие запроса не порождает: у подтверждающего сервиса лимит.
    probing: Arc<AtomicBool>,
}

impl AppState {
    pub fn new(paths: Paths) -> Arc<AppState> {
        let settings = SharedSettings::load(&paths);
        let journal = Arc::new(Mutex::new(Journal::load(&paths.journal_file())));

        let writer = JournalWriter {
            paths: paths.clone(),
            journal: journal.clone(),
            episode: Mutex::new(Episode::default()),
            notifier: Box::new(PortalNotifier::new()),
        };

        let controller = Arc::new(GuardController::new(
            Box::new(KernelNetworkReader::new()),
            Box::new(HttpGeoProbe::new(
                GeoEndpoints::default(),
                Box::new(RouteNetworkPath),
            )),
            Box::new(FileSecretStore::new(paths.token_file())),
            Box::new(SettingsSource(settings.clone())),
            ProcessEnforcer::new(Box::new(ProcRegistry::new()), Box::new(SigtermKiller)),
            Box::new(writer),
        ));

        Arc::new(AppState {
            paths,
            settings,
            controller,
            journal,
            probing: Arc::new(AtomicBool::new(false)),
        })
    }

    pub fn snapshot(&self) -> GuardSnapshot {
        self.controller.snapshot()
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

        let export = weto_config::export::JournalExport::build(
            &settings,
            events,
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

    /// Состояние охраны в терминах экрана. Собирается из настроек и снимка:
    /// вердикта может ещё не быть, и до первой пробы это `verificationPending` —
    /// то же fail-closed, что применяется к целям.
    pub fn guard_state(&self) -> GuardState {
        let settings = self.settings.current();
        let snapshot = self.snapshot();
        let decision = snapshot
            .decision
            .clone()
            .unwrap_or(GuardDecision::Kill(UnsafeReason::VerificationPending));

        GuardState {
            is_enabled: settings.is_enabled,
            has_targets: !settings.targets.is_empty(),
            // Цели живут, но ipinfo молчит: защита держится на доказанной
            // неизменности адреса, и щит обязан быть жёлтым, а не зелёным.
            is_degraded: matches!(decision, GuardDecision::Safe)
                && snapshot
                    .report
                    .as_ref()
                    .is_some_and(|r| matches!(r.ipinfo, SourceOutcome::Failed(_))),
            decision,
            country: None,
        }
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
                let events = NetlinkEventSource.subscribe();
                loop {
                    let decision = controller.tick();
                    // Шаг штатного тика перечитывается каждый раз: правка
                    // в настройках применяется со следующего же круга.
                    let interval = match decision {
                        GuardDecision::Safe => TICK_SAFE,
                        GuardDecision::Kill(_) => TICK_UNSAFE,
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
