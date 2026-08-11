//! Обновление со стороны приложения: проверка, показ, установка, перезапуск.
//!
//! Проверка идёт на фоновом потоке, решение о показе принимает чистая функция
//! из `weto-update`, а окно и баннер живут в главном цикле GTK. Установка
//! тоже фоновая: HTTP блокирующий, а главный поток занят отрисовкой.

use std::cell::RefCell;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use weto_update::checker::ReleaseChecker;
use weto_update::installer::Installer;
use weto_update::layout::Layout;
use weto_update::policy::{UpdateDeferral, UpdateInfo};
use weto_update::rollback::{roll_back_if_needed, LaunchMarker};
use weto_update::scheduler::{DeferralReading, Finding, UpdateScheduler};
use weto_update::store::UpdateStore;
use weto_update::version::Version;

use crate::state::AppState;

const REPOSITORY: &str = "squaretus/weto";

/// Версия приходит из окружения сборки: релизный скрипт не правит
/// отслеживаемые файлы, поэтому в `Cargo.toml` она остаётся нулевой.
pub fn current_version() -> Version {
    option_env!("WETO_VERSION")
        .and_then(Version::parse)
        .unwrap_or(Version {
            major: 0,
            minor: 0,
            patch: 0,
        })
}

/// Ход установки — то, что видит окно.
#[derive(Debug, Clone, PartialEq)]
pub enum Progress {
    Idle,
    Running(f32),
    Failed(String),
    /// Установка удалась; дальше только перезапуск.
    Installed,
}

pub struct Updates {
    store: Arc<UpdateStore>,
    installer: Arc<Installer>,
    progress: Arc<Mutex<Progress>>,
    /// Найденное обновление, если о нём стоит говорить.
    pending: Arc<Mutex<Option<UpdateInfo>>>,
}

pub struct StoreDeferrals(pub Arc<UpdateStore>);

impl DeferralReading for StoreDeferrals {
    fn deferral(&self) -> UpdateDeferral {
        self.0.deferral()
    }
}

thread_local! {
    static UPDATES: RefCell<Option<Arc<Updates>>> = const { RefCell::new(None) };
}

pub fn shared() -> Option<Arc<Updates>> {
    UPDATES.with(|slot| slot.borrow().clone())
}

impl Updates {
    pub fn pending(&self) -> Option<UpdateInfo> {
        self.pending.lock().expect("обновление").clone()
    }

    pub fn progress(&self) -> Progress {
        self.progress.lock().expect("обновление").clone()
    }

    /// «Позже»: окно не всплывает до срока. Дата абсолютная и переживает
    /// перезапуск, а дальше шести часов считается испорченной — перевод часов
    /// назад иначе запер бы обновления.
    pub fn remind_later(&self) {
        self.store.remind_later(Duration::from_secs(3600));
        *self.pending.lock().expect("обновление") = None;
    }

    /// «Пропустить эту версию»: действует до выхода версии выше и снимается сам.
    pub fn skip(&self, version: &str) {
        self.store.skip(version);
        *self.pending.lock().expect("обновление") = None;
    }

    /// Установка на рабочем потоке. Окно читает ход через `progress`.
    pub fn install(self: &Arc<Self>, info: &UpdateInfo) {
        let Some(version) = Version::parse(&info.latest_version) else {
            *self.progress.lock().expect("обновление") =
                Progress::Failed("версия релиза не разбирается".into());
            return;
        };

        let updates = self.clone();
        let url = info.download_url.clone();
        *self.progress.lock().expect("обновление") = Progress::Running(0.0);

        std::thread::spawn(move || {
            let installer = updates.installer.clone();
            let watched = updates.clone();

            // Доля обновляется отдельным потоком: установщик считает её сам,
            // а спрашивать его из главного цикла значило бы держать блокировку.
            let watcher = std::thread::spawn(move || loop {
                let current = watched.progress.lock().expect("обновление").clone();
                if !matches!(current, Progress::Running(_)) {
                    return;
                }
                *watched.progress.lock().expect("обновление") =
                    Progress::Running(watched.installer.progress());
                std::thread::sleep(Duration::from_millis(200));
            });

            let outcome = installer.install(&version, &url);
            *updates.progress.lock().expect("обновление") = match outcome {
                Ok(()) => {
                    updates.store.clear();
                    Progress::Installed
                }
                Err(error) => Progress::Failed(error.to_string()),
            };
            let _ = watcher.join();
        });
    }

    /// Ручная проверка игнорирует пропуск и отсрочку.
    pub fn check_now(self: &Arc<Self>) {
        let updates = self.clone();
        std::thread::spawn(move || {
            let scheduler = UpdateScheduler::new(
                current_version(),
                Arc::new(ReleaseChecker::new(REPOSITORY, std::env::consts::ARCH)),
                Arc::new(StoreDeferrals(updates.store.clone())),
            );
            if let Some(Finding::Prompt(info)) | Some(Finding::Install(info)) =
                scheduler.check(true)
            {
                *updates.pending.lock().expect("обновление") = Some(info);
            }
        });
    }
}

/// Перезапуск после установки.
///
/// `exec` заменяет процесс: пусковой симлинк уже указывает на новую версию,
/// поэтому запускается именно она. Плавного завершения GTK не требуется —
/// окна закрывает ядро вместе со старым образом процесса.
pub fn restart() -> ! {
    use std::os::unix::process::CommandExt;

    let launcher = std::env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_default()
        .join(".local/bin/weto");

    // Пусковой симлинк — обычный путь запуска, но у сборки из исходников
    // его может не быть. Тогда перезапускаем сам исполняемый файл: он ведёт
    // в тот же каталог версии, просто без промежуточной ссылки.
    let target = if launcher.exists() {
        launcher
    } else {
        std::env::current_exe().unwrap_or(launcher)
    };

    let error = std::process::Command::new(&target).exec();
    eprintln!("weto: перезапуск не удался ({}): {error}", target.display());
    std::process::exit(1);
}

/// Проверяет, не пора ли откатиться, и ставит отметку о попытке запуска.
///
/// Вызывается до создания окон. Отметка снимается, когда приложение проживёт
/// несколько секунд: две неудачные попытки подряд означают, что новая версия
/// не стартует, и возвращаться надо к предыдущей.
pub fn guard_the_launch(state: &Arc<AppState>) {
    let layout = Layout::new(state.paths.data_dir.clone());
    let marker = LaunchMarker::new(state.paths.state_dir.clone());

    if let Some(previous) = roll_back_if_needed(&layout, &marker) {
        eprintln!("weto: версия не стартует, возвращаемся к {previous}");
        restart();
    }

    let _ = marker.mark();
}

/// Запускает фоновую проверку и подписывает главный цикл на находки.
pub fn start(state: Arc<AppState>) {
    let store = Arc::new(UpdateStore::new(state.paths.state_dir.clone()));
    let updates = Arc::new(Updates {
        store: store.clone(),
        installer: Arc::new(Installer::new(
            Layout::new(state.paths.data_dir.clone()),
            state.paths.cache_dir.join("updates"),
        )),
        progress: Arc::new(Mutex::new(Progress::Idle)),
        pending: Arc::new(Mutex::new(None)),
    });
    UPDATES.with(|slot| *slot.borrow_mut() = Some(updates.clone()));

    let findings = UpdateScheduler::new(
        current_version(),
        Arc::new(ReleaseChecker::new(REPOSITORY, std::env::consts::ARCH)),
        Arc::new(StoreDeferrals(store)),
    )
    .start();

    let marker = LaunchMarker::new(state.paths.state_dir.clone());
    let mut alive_ticks = 0u32;

    gtk4::glib::timeout_add_local(Duration::from_millis(500), move || {
        // Пять секунд без падения — версия рабочая, отметку можно снять.
        alive_ticks += 1;
        if alive_ticks == 10 {
            let _ = marker.clear();
        }

        while let Ok(finding) = findings.try_recv() {
            match finding {
                Finding::Prompt(info) => {
                    *updates.pending.lock().expect("обновление") = Some(info);
                }
                // Автоустановка идёт молча: ни окна, ни баннера.
                Finding::Install(info) => updates.install(&info),
            }
        }

        if updates.progress() == Progress::Installed {
            restart();
        }

        gtk4::glib::ControlFlow::Continue
    });
}
