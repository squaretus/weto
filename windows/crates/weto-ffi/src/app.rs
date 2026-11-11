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
use weto_core::guard_machine::GuardPhase;
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

use weto_update::checker::ReleaseChecker;
use weto_update::scheduler::{ReleaseLooking, UpdateScheduler};
use weto_update::updates::Updates;

use crate::command::{apply_to_settings, Command};
use crate::update::{
    asset_suffix, current_version, update_view, SetupInstaller, UpdateView, REPOSITORY,
};
use crate::view::{
    journal_view, settings_view, status_view, tick_view, IconRef, JournalView, SettingsView,
    StatusView, TickView,
};

/// Охрана держит цели: пауза или запрет запуска. Пока так, установщик
/// обновления не запускается — его начало это штатный выход, а выход
/// продолжает цели и снимает запрет на всё время установки.
///
/// Только по фазе, а не по стоящим в снимке: вне паузы там остаются лишь
/// записи, которые досылки SIGCONT поднять не смогли (`resumeRetryLimit`),
/// и выход продолжает их так же, как любой другой. Держать установку ради
/// них значило бы ждать вечно — без потолка и без отмены.
fn guard_holds_targets(controller: Arc<GuardController>) -> impl Fn() -> bool + Send + Sync {
    move || {
        matches!(
            controller.snapshot().phase,
            GuardPhase::Paused { .. } | GuardPhase::Danger(_)
        )
    }
}

pub struct WindowsApp {
    paths: Paths,
    settings: Arc<SharedSettings>,
    controller: Arc<GuardController>,
    journal: Arc<Mutex<Journal>>,
    checks: Arc<Mutex<CheckLog>>,
    secrets: CredentialStore,
    autostart: RunKeyAutostart,
    updates: Arc<Updates>,
    checker: Arc<dyn ReleaseLooking>,
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

        let arch = std::env::consts::ARCH;
        let checker: Arc<dyn ReleaseLooking> =
            Arc::new(ReleaseChecker::new(REPOSITORY, arch).with_asset_suffix(asset_suffix(arch)));
        let updates = Updates::new(
            paths.state_dir.clone(),
            Arc::new(SetupInstaller::new(
                paths.cache_dir.join("updates"),
                arch,
                Box::new(guard_holds_targets(controller.clone())),
            )),
            checker.clone(),
            current_version(),
        );

        WindowsApp {
            paths,
            settings,
            controller,
            journal,
            checks,
            secrets: CredentialStore::new(IPINFO_TARGET),
            autostart: RunKeyAutostart::new(VALUE_NAME),
            updates,
            checker,
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

        // Проверка обновлений по расписанию: находки применяет свой поток —
        // `Updates` потокобезопасен, а интерфейс читает итог опросом вида.
        let findings = UpdateScheduler::new(
            current_version(),
            self.checker.clone(),
            self.updates.deferrals(),
        )
        .start();
        let updates = self.updates.clone();
        std::thread::Builder::new()
            .name("weto-updates".into())
            .spawn(move || {
                for examination in findings {
                    updates.apply(examination);
                }
            })
            .expect("поток обновлений не поднялся");
    }

    /// Обновление: баннер, окно, плитка подвала. Просьба открыть окно
    /// забирается этим чтением — опрашивает вид один интерфейс.
    pub fn update(&self) -> UpdateView {
        let requested = self.updates.take_window_request().is_some();
        update_view(&self.updates, requested)
    }

    pub fn status(&self) -> StatusView {
        let mut view = status_view(
            &self.controller.snapshot(),
            !self.settings.current().targets.is_empty(),
            self.controller.is_probing(),
            SystemTime::now(),
            &clock::local_hms,
        );
        // Значок приложения — только у цели-ярлыка, как Icon= у .desktop.
        if let Some(targets) = view.targets.as_mut() {
            for pill in targets.pills.iter_mut().filter(|pill| !pill.command_line) {
                pill.icon = weto_sys_windows::shortcut::icon(std::path::Path::new(&pill.entry))
                    .map(|(path, index)| IconRef { path, index });
            }
        }
        view
    }

    pub fn tick(&self) -> TickView {
        tick_view(
            &self.settings.current(),
            &self.controller.snapshot().running,
        )
    }

    pub fn settings(&self) -> SettingsView {
        settings_view(
            &self.settings.current(),
            &self.controller.snapshot().running,
            &self.token(),
            self.autostart.command().is_some(),
            &|entry| WindowsTargetResolver.locate(entry).map(|found| found.path),
        )
    }

    /// Сам токен — только для поля в фокусе (вид «token»); вне фокуса окно
    /// показывает маску из вида настроек.
    pub fn token(&self) -> String {
        self.secrets.load().ok().flatten().unwrap_or_default()
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
                // Текст поля как есть: маска, её обломок и показ записанного
                // токена при входе в поле — не ввод. Решает общий помощник,
                // тот же, что у окна Linux.
                let stored = self.token();
                if let Some(token) = weto_core::presentation::token_to_save(&token, &stored) {
                    if token.is_empty() {
                        self.secrets.delete().map_err(|e| e.to_string())?;
                    } else {
                        self.secrets.save(&token).map_err(|e| e.to_string())?;
                    }
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
            Command::CheckUpdates => {
                if self.updates.found().is_some() {
                    return Ok(Value::Bool(true));
                }
                self.updates.check_now();
                return Ok(Value::Bool(false));
            }
            Command::InstallUpdate => {
                if let Some(info) = self.updates.pending() {
                    self.updates.install(&info);
                }
            }
            Command::SkipUpdate => {
                if let Some(info) = self.updates.pending() {
                    self.updates.skip(&info.latest_version);
                }
            }
            Command::RemindLater { interval } => self.updates.remind_later(interval.into()),
            Command::DismissUpdate => self.updates.dismiss(),
            Command::SetAutoInstall { enabled } => self.updates.set_auto_install(enabled),
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

    /// Проверка перед сносом — без запуска охраны: SIGCONT по учёту и круги
    /// наблюдения (`uninstall::confirm_resumed`). Работающий экземпляр
    /// к этому моменту уже вышел.
    pub fn uninstall_check(&self) -> crate::uninstall::UninstallCheck {
        self.controller.shutdown();
        let standing = crate::uninstall::confirm_resumed(
            || self.controller.confirm_resumed(),
            std::thread::sleep,
        );
        crate::uninstall::check_view(&standing)
    }

    /// Снос того, что лежит вне каталогов данных: токен в Диспетчере учётных
    /// данных и автозапуск в `HKCU\…\Run`. Каталоги сносит деинсталлятор —
    /// учёт остановленных последним.
    pub fn uninstall_cleanup(&self) -> Result<(), String> {
        let token = self
            .secrets
            .delete()
            .map_err(|e| format!("токен не удалён: {e}"));
        let autostart = self
            .autostart
            .disable()
            .map_err(|e| format!("автозапуск не снят: {e}"));
        token.and(autostart)
    }
}
