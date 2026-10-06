//! Плитка обновления в подвале настроек — порт `SettingsFooter` с macOS.
//!
//! Окно настроек строится тем же кодом, что и в продукте; источник релизов
//! подменён и ждёт разрешения ответить — так видно, что плитка делает,
//! пока проверка идёт. Отдельным файлом, потому что отдельным процессом:
//! GTK инициализируется один раз и ровно из одного потока.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};

use gtk4::glib::MainContext;
use gtk4::prelude::*;
use gtk4::{Application, Button, Widget};

use weto_app::settings_window;
use weto_app::state::AppState;
use weto_app::update::{self, Updates};
use weto_config::paths::Paths;
use weto_update::checker::CheckError;
use weto_update::policy::UpdateInfo;
use weto_update::scheduler::{CheckState, Examination};
use weto_update::version::Version;

struct GatedReleases {
    gate: Mutex<mpsc::Receiver<()>>,
    calls: Arc<AtomicUsize>,
}

impl weto_update::scheduler::ReleaseLooking for GatedReleases {
    fn latest(&self, current: &Version) -> Result<UpdateInfo, CheckError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        let _ = self.gate.lock().unwrap().recv();
        Ok(UpdateInfo {
            current_version: current.to_string(),
            latest_version: "1.2.0".to_string(),
            release_url: "https://github.com/squaretus/weto/releases/tag/v1.2.0".to_string(),
            download_url: "https://evil.example/weto.tar.zst".to_string(),
            is_newer: true,
        })
    }
}

/// Одним тестом: окно настроек одно на процесс.
#[test]
fn the_update_tile_follows_the_check_like_macos() {
    gtk4::init().expect("тесту нужен дисплей: Xvfb не поднят");

    let application = Application::builder()
        .application_id("com.weto.app.tests.footer")
        .flags(gtk4::gio::ApplicationFlags::NON_UNIQUE)
        .build();
    application
        .register(gtk4::gio::Cancellable::NONE)
        .expect("приложение не зарегистрировалось");
    let _hold = application.hold();

    let home = std::env::temp_dir().join(format!("weto-settings-footer-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).expect("временный дом не создался");
    let state: Arc<AppState> = AppState::new(Paths::rooted(home.clone()));

    let (open, gate) = mpsc::channel();
    let calls = Arc::new(AtomicUsize::new(0));
    let updates = Updates::new(
        &state.paths,
        Arc::new(GatedReleases {
            gate: Mutex::new(gate),
            calls: calls.clone(),
        }),
        Version::parse("1.1.0").unwrap(),
    );
    update::register(updates.clone());

    settings_window::present(&application, state.clone());
    let settings = application
        .windows()
        .into_iter()
        .next()
        .expect("окно настроек не открылось");
    pump(Duration::from_millis(100));
    let tile = descendants::<Button>(settings.upcast_ref())
        .into_iter()
        .find(|button| button.has_css_class("weto-tile-button"))
        .expect("нет плитки обновления");

    assert_eq!(tile.tooltip_text().as_deref(), Some("Проверить обновления"));
    assert!(tile.is_sensitive());

    // --- Пока идёт проверка, плитка неактивна, и такт её не оживляет --------

    tile.emit_clicked();
    assert!(!tile.is_sensitive(), "плитка нажимается посреди проверки");
    pump(Duration::from_millis(700));
    assert!(
        !tile.is_sensitive(),
        "такт оживил плитку до ответа проверки"
    );
    assert_eq!(updates.state(), CheckState::Checking);

    open.send(()).unwrap();
    wait_for(|| tile.is_sensitive());

    // --- Находка: подсказка, иконка и окно -----------------------------------

    assert_eq!(
        tile.tooltip_text().as_deref(),
        Some("Доступна 1.2.0 — нажмите, чтобы открыть окно обновления")
    );
    assert_eq!(
        tile.icon_name().as_deref(),
        Some("software-update-available-symbolic")
    );
    update::present_requested(&application);
    assert_eq!(application.windows().len(), 2, "находка не открыла окно");
    let dialog = update_window(&application);

    // Пропуск закрывает окно ответом, а не крестиком.
    find_button(dialog.upcast_ref(), "Пропустить версию").emit_clicked();
    pump(Duration::from_millis(100));
    assert_eq!(application.windows().len(), 1);

    // Найденная версия открывает окно, а не проверяет заново.
    tile.emit_clicked();
    pump(Duration::from_millis(100));
    assert_eq!(application.windows().len(), 2, "плитка не открыла окно");
    assert_eq!(calls.load(Ordering::SeqCst), 1, "плитка проверила заново");
    update_window(&application).close();
    pump(Duration::from_millis(100));

    // --- Исходы без находки называются словами macOS -------------------------

    for (state, hint) in [
        (
            CheckState::UpToDate("1.1.0".to_string()),
            "1.1.0 — последняя версия",
        ),
        (CheckState::NoReleases, "Релизов пока нет"),
        (
            CheckState::Failed("не спросить о релизах: нет сети".to_string()),
            "не спросить о релизах: нет сети",
        ),
    ] {
        updates.apply(Examination {
            state,
            finding: None,
        });
        // Плитку перерисовывает такт окна, а не сам исход: ждём его по условию,
        // а не фиксированным временем — под нагрузкой такт приходит позже.
        wait_for(|| tile.tooltip_text().as_deref() == Some(hint));
        assert_eq!(tile.icon_name().as_deref(), Some("view-refresh-symbolic"));
    }

    settings.close();
    pump(Duration::from_millis(100));
    let _ = std::fs::remove_dir_all(&home);
}

fn update_window(application: &Application) -> gtk4::Window {
    application
        .windows()
        .into_iter()
        .find(|window| window.title().as_deref() == Some("Обновление Weto"))
        .expect("нет окна обновления")
}

fn descendants<T: IsA<Widget>>(root: &Widget) -> Vec<T> {
    let mut found = Vec::new();
    let mut stack = vec![root.clone()];
    while let Some(widget) = stack.pop() {
        let mut children = Vec::new();
        let mut child = widget.first_child();
        while let Some(next) = child {
            child = next.next_sibling();
            children.push(next);
        }
        stack.extend(children.into_iter().rev());
        if let Ok(typed) = widget.downcast::<T>() {
            found.push(typed);
        }
    }
    found
}

fn find_button(root: &Widget, text: &str) -> Button {
    descendants::<Button>(root)
        .into_iter()
        .find(|button| button.label().as_deref() == Some(text))
        .unwrap_or_else(|| panic!("нет кнопки «{text}»"))
}

fn pump(duration: Duration) {
    let context = MainContext::default();
    let deadline = Instant::now() + duration;
    while Instant::now() < deadline {
        while context.iteration(false) {}
        std::thread::sleep(Duration::from_millis(1));
    }
}

fn wait_for(done: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !done() {
        assert!(Instant::now() < deadline, "не дождались");
        pump(Duration::from_millis(20));
    }
}
