//! Обновление со стороны приложения: проверка, показ, установка, перезапуск.
//!
//! Проверка идёт на фоновом потоке, решение о показе принимает чистая функция
//! из `weto-update`, а окно и баннер живут в главном цикле GTK. Установка
//! тоже фоновая: HTTP блокирующий, а главный поток занят отрисовкой.

use std::cell::RefCell;
use std::sync::Arc;
use std::time::Duration;

use weto_config::paths::Paths;
use weto_update::checker::ReleaseChecker;
use weto_update::installer::Installer;
use weto_update::layout::Layout;
use weto_update::rollback::{roll_back_if_needed, LaunchMarker};
use weto_update::scheduler::{ReleaseLooking, UpdateScheduler};
use weto_update::version::Version;

pub use weto_update::updates::{
    footer_hint, footer_shows_update, Progress, StoreDeferrals, Updates,
};

use crate::state::AppState;

const REPOSITORY: &str = "squaretus/weto";

/// Ссылка из подвала настроек. Тот же репозиторий, что и у проверки обновлений:
/// расходиться им нельзя.
pub const REPOSITORY_URL: &str = "https://github.com/squaretus/weto";

/// Страница релизов — ручной путь, когда своей страницы у находки нет.
pub const RELEASES_URL: &str = "https://github.com/squaretus/weto/releases";

/// Имя приложения в текстах обновления — как `appDisplayName` на macOS.
pub const APP_NAME: &str = "Weto";

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

thread_local! {
    static UPDATES: RefCell<Option<Arc<Updates>>> = const { RefCell::new(None) };
}

pub fn shared() -> Option<Arc<Updates>> {
    UPDATES.with(|slot| slot.borrow().clone())
}

/// Делает механизм доступным окнам. Отдельно от `start`, чтобы тест окна
/// подставил свой источник релизов и не ходил в сеть.
pub fn register(updates: Arc<Updates>) {
    UPDATES.with(|slot| *slot.borrow_mut() = Some(updates));
}

/// Механизм обновления с установщиком Linux: архив в версионный каталог
/// и подмена симлинка `current`.
pub fn linux_updates(
    paths: &Paths,
    checker: Arc<dyn ReleaseLooking>,
    current: Version,
) -> Arc<Updates> {
    Updates::new(
        paths.state_dir.clone(),
        Arc::new(Installer::new(
            Layout::new(paths.data_dir.clone()),
            paths.cache_dir.join("updates"),
        )),
        checker,
        current,
    )
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
pub fn start(app: &gtk4::Application, state: Arc<AppState>) {
    let checker: Arc<dyn ReleaseLooking> =
        Arc::new(ReleaseChecker::new(REPOSITORY, std::env::consts::ARCH));
    let updates = linux_updates(&state.paths, checker.clone(), current_version());
    register(updates.clone());

    let findings = UpdateScheduler::new(current_version(), checker, updates.deferrals()).start();

    let marker = LaunchMarker::new(state.paths.state_dir.clone());
    let mut alive_ticks = 0u32;
    let app = app.clone();

    gtk4::glib::timeout_add_local(Duration::from_millis(500), move || {
        // Пять секунд без падения — версия рабочая, отметку можно снять.
        alive_ticks += 1;
        if alive_ticks == 10 {
            let _ = marker.clear();
        }

        while let Ok(examination) = findings.try_recv() {
            updates.apply(examination);
        }
        present_requested(&app);

        if updates.progress() == Progress::Installed {
            restart();
        }

        gtk4::glib::ControlFlow::Continue
    });
}

/// Окно, которое просила находка, — открывает главный цикл. Находка приходит
/// с чужого потока (проверки по расписанию или по кнопке), а окна строятся
/// только здесь.
pub fn present_requested(app: &gtk4::Application) {
    if let Some(info) = shared().and_then(|updates| updates.take_window_request()) {
        crate::update_window::present(app, &info);
    }
}
