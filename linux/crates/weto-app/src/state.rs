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

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use weto_config::journal::{Journal, KillEvent, KillEventKind};
use weto_config::paths::Paths;
use weto_config::settings::{Settings, Theme};
use weto_core::policy::GuardDecision;
use weto_core::process::MatchedProcess;
use weto_guard::controller::{GuardController, GuardSnapshot, KillReporting, SettingsProviding};
use weto_guard::enforcer::ProcessEnforcer;
use weto_sys::geo_probe::{GeoEndpoints, HttpGeoProbe, RouteNetworkPath};
use weto_sys::network_events::{NetlinkEventSource, NetworkEventSourcing};
use weto_sys::network_snapshot::SysfsNetworkReader;
use weto_sys::notifications::{KillNotifying, PortalNotifier};
use weto_sys::process_killer::SigtermKiller;
use weto_sys::process_registry::ProcRegistry;
use weto_sys::secret_store::FileSecretStore;

/// Пока небезопасно — 250 мс: терминальные цели больше ничем не поймать.
/// Когда всё сошлось — 5 секунд.
const TICK_UNSAFE: Duration = Duration::from_millis(250);
const TICK_SAFE: Duration = Duration::from_secs(5);

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

/// Журнал пишет каждый новый pid и каждую новую причину в рамках эпизода.
/// Без этого запись «подключение ещё не проверено» съедала бы настоящую
/// причину: она приходит первой, а интересна последняя.
struct JournalWriter {
    paths: Paths,
    journal: Mutex<Journal>,
    last_reason: Mutex<Option<String>>,
    notifier: Box<dyn KillNotifying>,
    notify: Arc<AtomicBool>,
}

impl KillReporting for JournalWriter {
    fn report(&self, killed: &[MatchedProcess], reason: &str) {
        let mut last = self.last_reason.lock().expect("журнал");
        let same_episode = last.as_deref() == Some(reason);
        *last = Some(reason.to_string());
        drop(last);

        if same_episode {
            return;
        }

        let names: Vec<String> = {
            let mut names: Vec<String> = killed.iter().map(|k| k.target_name.clone()).collect();
            names.sort();
            names.dedup();
            names
        };

        let event = KillEvent {
            at: std::time::SystemTime::now(),
            target_names: names.clone(),
            kind: KillEventKind::Terminated,
            reason_text: reason.to_string(),
            ip: None,
            country: None,
            confirmed_country: None,
            confirm_source: None,
            killed_pids: killed.iter().map(|k| k.pid).collect(),
        };

        if self.notify.load(Ordering::Relaxed) {
            self.notifier.notify(&names, reason);
        }

        let mut journal = self.journal.lock().expect("журнал");
        journal.append(event);
        if let Err(error) = journal.save(&self.paths.journal_file()) {
            eprintln!("weto: журнал не сохранился: {error}");
        }
    }
}

pub struct AppState {
    pub paths: Paths,
    pub settings: Arc<SharedSettings>,
    controller: Arc<GuardController>,
    journal: Arc<Mutex<Journal>>,
    notify: Arc<AtomicBool>,
}

impl AppState {
    pub fn new(paths: Paths) -> Arc<AppState> {
        let settings = SharedSettings::load(&paths);
        let notify = Arc::new(AtomicBool::new(settings.current().notify_on_kill));
        let journal = Arc::new(Mutex::new(Journal::load(&paths.journal_file())));

        let writer = JournalWriter {
            paths: paths.clone(),
            journal: Mutex::new(Journal::load(&paths.journal_file())),
            last_reason: Mutex::new(None),
            notifier: Box::new(PortalNotifier::new()),
            notify: notify.clone(),
        };

        let controller = Arc::new(GuardController::new(
            Box::new(SysfsNetworkReader::new()),
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
            notify,
        })
    }

    pub fn snapshot(&self) -> GuardSnapshot {
        self.controller.snapshot()
    }

    pub fn journal(&self) -> Journal {
        self.journal.lock().expect("журнал").clone()
    }

    pub fn reload_journal(&self) {
        let fresh = Journal::load(&self.paths.journal_file());
        *self.journal.lock().expect("журнал") = fresh;
    }

    pub fn theme(&self) -> Theme {
        self.settings.current().theme
    }

    pub fn set_notify(&self, enabled: bool) {
        self.notify.store(enabled, Ordering::Relaxed);
    }

    /// Проверка по кнопке уходит на рабочий поток: HTTP блокирующий,
    /// а главный поток занят отрисовкой.
    pub fn probe_now(&self) {
        let controller = self.controller.clone();
        std::thread::spawn(move || {
            controller.probe_now();
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
