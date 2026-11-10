//! Состояние приложения Windows — аналог `weto-app/src/state.rs` Linux.
//!
//! Охрана собирается из тех же частей, что на Linux (`GuardController`,
//! `ProcessEnforcer`, писатели журналов), но на адаптерах `weto-sys-windows`.
//! Терминальной части нет: job control на Windows нет, и цель от паузы
//! в фон не уходит.

use std::sync::{Arc, Mutex};
use std::time::SystemTime;

use serde_json::{json, Value};

use weto_config::checks::CheckLog;
use weto_config::journal::Journal;
use weto_config::paths::Paths;
use weto_guard::controller::GuardController;
use weto_guard::enforcer::ProcessEnforcer;
use weto_guard::runtime::{spawn_guard, CheckWriter, JournalWriter};
use weto_guard::shared_settings::{SettingsSource, SharedSettings};
use weto_sys::geo_probe::{GeoEndpoints, HttpGeoProbe, RouteNetworkPath};
use weto_sys::network_snapshot::{KernelNetworkReader, KernelRouteProbe};
use weto_sys::notifications::KillNotifying;
use weto_sys::secret_store::SecretStoring;
use weto_sys::target_resolver::TargetResolving;
use weto_sys_windows::autostart::{RunKeyAutostart, VALUE_NAME};
use weto_sys_windows::clock;
use weto_sys_windows::interfaces::AdapterInterfaces;
use weto_sys_windows::network_events::IpHelperEventSource;
use weto_sys_windows::process_registry::NtProcessRegistry;
use weto_sys_windows::process_signaler::WindowsProcessSignaler;
use weto_sys_windows::secret_store::{CredentialStore, IPINFO_TARGET};
use weto_sys_windows::target_resolver::{settings_target_now, WindowsTargetResolver};

use crate::command::{apply_to_settings, Command};
use crate::view::{
    journal_view, settings_view, status_view, JournalView, SettingsView, StatusView,
};

pub struct WindowsApp {
    paths: Paths,
    settings: Arc<SharedSettings>,
    controller: Arc<GuardController>,
    journal: Arc<Mutex<Journal>>,
    checks: Arc<Mutex<CheckLog>>,
    secrets: CredentialStore,
    autostart: RunKeyAutostart,
}

impl WindowsApp {
    pub fn new(paths: Paths, notifier: Box<dyn KillNotifying>) -> WindowsApp {
        let settings = SharedSettings::load(&paths);
        let journal = Arc::new(Mutex::new(Journal::load(&paths.journal_file())));
        let checks = Arc::new(Mutex::new(CheckLog::load(&paths.checks_file())));

        let controller = Arc::new(GuardController::with_target_resolution(
            Box::new(KernelNetworkReader::with_sources(
                Box::new(KernelRouteProbe::default()),
                Box::new(AdapterInterfaces),
            )),
            Box::new(HttpGeoProbe::new(
                GeoEndpoints::default(),
                Box::new(RouteNetworkPath),
            )),
            Box::new(CredentialStore::new(IPINFO_TARGET)),
            Box::new(SettingsSource(settings.clone())),
            ProcessEnforcer::new(
                Box::new(NtProcessRegistry::new()),
                Box::new(WindowsProcessSignaler),
                paths.stopped_file(),
            ),
            Box::new(JournalWriter::new(paths.clone(), journal.clone(), notifier)),
            Box::new(CheckWriter::new(paths.clone(), checks.clone())),
            Box::new(WindowsTargetResolver),
        ));

        WindowsApp {
            paths,
            settings,
            controller,
            journal,
            checks,
            secrets: CredentialStore::new(IPINFO_TARGET),
            autostart: RunKeyAutostart::new(VALUE_NAME),
        }
    }

    /// Охрана стартует с процессом, а не с первым окном: на macOS ровно эта
    /// ловушка (`MenuBarExtra` строит содержимое лениво) оставляла машину
    /// без защиты, пока меню не откроют. Отказ от EcoQoS — до первого такта.
    pub fn start(&self) {
        if let Err(code) = weto_sys_windows::power::keep_full_speed() {
            eprintln!("weto: отказ от троттлинга не принят: код {code}");
        }
        spawn_guard(
            self.controller.clone(),
            Box::new(IpHelperEventSource),
            |_| {},
        );
    }

    pub fn status(&self) -> StatusView {
        status_view(
            &self.controller.snapshot(),
            !self.settings.current().targets.is_empty(),
            self.controller.is_probing(),
            SystemTime::now(),
            &clock::local_hms,
        )
    }

    pub fn settings(&self) -> SettingsView {
        let token_set = self
            .secrets
            .load()
            .ok()
            .flatten()
            .is_some_and(|token| !token.is_empty());
        settings_view(
            &self.settings.current(),
            token_set,
            self.autostart.command().is_some(),
            &|entry| WindowsTargetResolver.locate(entry).map(|found| found.path),
        )
    }

    pub fn journal(&self) -> JournalView {
        let journal = self.journal.lock().expect("журнал");
        journal_view(journal.entries(), &|at| {
            weto_core::timestamp::to_local_display(at, i64::from(clock::utc_offset(at)))
        })
    }

    /// Команда интерфейса. `Ok(значение)` — исполнена; `Err(текст)` — отказ,
    /// который окно покажет пользователю.
    pub fn command(&self, command: Command) -> Result<Value, String> {
        if let Some(outcome) = apply_to_settings(&command, &self.settings, &settings_target_now) {
            return outcome.map(|()| Value::Null);
        }
        match command {
            Command::ProbeNow => {
                // Ответ пробы придёт своим проходом; экран увидит его следующим опросом.
                self.controller.probe_now();
            }
            Command::SetToken { token } => {
                let token = token.trim();
                if token.is_empty() {
                    self.secrets.delete().map_err(|e| e.to_string())?;
                } else {
                    self.secrets.save(token).map_err(|e| e.to_string())?;
                }
            }
            Command::ClearToken => self.secrets.delete().map_err(|e| e.to_string())?,
            Command::SetAutostart { enabled } => {
                let result = if enabled {
                    self.autostart.enable(&self.paths.launcher)
                } else {
                    self.autostart.disable()
                };
                result.map_err(|e| e.to_string())?;
            }
            Command::ExportJournal { path } => {
                let text = self.export_journal()?;
                std::fs::write(&path, text).map_err(|e| format!("журнал не записался: {e}"))?;
            }
            Command::ClearJournal => {
                let mut journal = self.journal.lock().expect("журнал");
                journal.clear();
                journal
                    .save(&self.paths.journal_file())
                    .map_err(|e| format!("журнал не очистился: {e}"))?;
            }
            Command::ConfirmResumed => {
                let standing = self.controller.confirm_resumed();
                return Ok(json!(standing
                    .iter()
                    .map(|process| json!({"pid": process.pid, "path": process.executable_path}))
                    .collect::<Vec<_>>()));
            }
            // Правки настроек исполнены выше.
            _ => {}
        }
        Ok(Value::Null)
    }

    /// Журнал для разбора. Токен в файл не попадает — только признак, задан ли он.
    fn export_journal(&self) -> Result<String, String> {
        let has_token = self
            .secrets
            .load()
            .ok()
            .flatten()
            .is_some_and(|token| !token.is_empty());
        let events = self.journal.lock().expect("журнал").entries().to_vec();
        let checks = self
            .checks
            .lock()
            .expect("журнал проверок")
            .entries()
            .to_vec();
        weto_config::export::JournalExport::build(
            &self.settings.current(),
            events,
            checks,
            has_token,
            SystemTime::now(),
            clock::os_version(),
        )
        .encoded()
        .map_err(|e| format!("журнал не собрался: {e}"))
    }

    /// Штатный выход: замороженных целей не оставляем.
    pub fn shutdown(&self) {
        self.controller.shutdown();
    }
}
