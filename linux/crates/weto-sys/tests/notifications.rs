//! Уведомления проверяются на настоящей шине.
//!
//! Контейнер даёт `dbus-daemon`, поэтому подменять здесь нечего: тест
//! поднимает свою сессионную шину, вешает на неё поддельный сервер уведомлений
//! и смотрит, что именно weto ему сказал и что сделал в ответ на нажатие.
//! Живого рабочего стола это не заменяет — как уведомление выглядит и приходит
//! ли оно вообще, проверяется глазами (`linux/docs/manual-ui-check.md`), —
//! но текст, действие и реакция на нажатие проверяются машинно.
//!
//! Всё одним тестом намеренно: шина одна на процесс, а её адрес живёт
//! в переменной окружения, общей на все потоки `cargo test`.

use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use weto_sys::notifications::{DesktopNotifier, KillNotifying};

const ID: u32 = 4242;

#[derive(Debug, Clone)]
struct Call {
    app: String,
    summary: String,
    body: String,
    actions: Vec<String>,
}

struct FakeNotifications {
    calls: Arc<Mutex<Vec<Call>>>,
}

#[zbus::interface(name = "org.freedesktop.Notifications")]
impl FakeNotifications {
    fn get_capabilities(&self) -> Vec<String> {
        vec!["body".to_string(), "actions".to_string()]
    }

    #[allow(clippy::too_many_arguments)]
    fn notify(
        &self,
        app_name: String,
        _replaces_id: u32,
        _app_icon: String,
        summary: String,
        body: String,
        actions: Vec<String>,
        _hints: HashMap<String, zbus::zvariant::OwnedValue>,
        _expire_timeout: i32,
    ) -> u32 {
        self.calls.lock().expect("вызовы").push(Call {
            app: app_name,
            summary,
            body,
            actions,
        });
        ID
    }
}

#[test]
fn the_backgrounded_notification_carries_its_text_and_opens_weto_on_click() {
    let Some(mut daemon) = start_session_bus() else {
        eprintln!("dbus-daemon не найден — уведомления проверить нечем, пропускаю");
        return;
    };

    let calls: Arc<Mutex<Vec<Call>>> = Arc::new(Mutex::new(Vec::new()));
    let server = zbus::blocking::connection::Builder::session()
        .expect("сессионная шина")
        .name("org.freedesktop.Notifications")
        .expect("имя сервера")
        .serve_at(
            "/org/freedesktop/Notifications",
            FakeNotifications {
                calls: calls.clone(),
            },
        )
        .expect("объект сервера")
        .build()
        .expect("сервер уведомлений");

    let opened = Arc::new(AtomicBool::new(false));
    let flag = opened.clone();
    let notifier = DesktopNotifier::with_open_handler(Arc::new(move || {
        flag.store(true, Ordering::SeqCst);
    }));

    notifier.notify_backgrounded("nano");

    let call = wait_for(Duration::from_secs(5), || {
        calls.lock().expect("вызовы").first().cloned()
    })
    .expect("уведомление не дошло до сервера");

    assert_eq!(call.app, "weto");
    assert_eq!(
        call.summary, "Weto: nano вернулся в фон",
        "заголовок обязан совпадать с macOS слово в слово"
    );
    assert_eq!(
        call.body, "Процесс на паузе потерял терминал. Откройте терминал и введите fg.",
        "текст обязан совпадать с macOS слово в слово"
    );
    assert_eq!(
        call.actions,
        vec!["default".to_string(), "Открыть weto".to_string()],
        "сервер объявил, что умеет действия, — значит нажатие обязано быть"
    );

    // Нажатие: сервер сообщает о выбранном действии, weto просит показать окно.
    // Сигнал шлётся до тех пор, пока не дойдёт: идентификатор своего
    // уведомления weto записывает уже после ответа сервера.
    let fired = wait_for(Duration::from_secs(5), || {
        server
            .emit_signal(
                None::<&str>,
                "/org/freedesktop/Notifications",
                "org.freedesktop.Notifications",
                "ActionInvoked",
                &(ID, "default"),
            )
            .expect("сигнал");
        opened.load(Ordering::SeqCst).then_some(())
    });
    assert!(
        fired.is_some(),
        "нажатие на уведомление обязано открывать окно статуса"
    );

    let _ = daemon.kill();
    let _ = daemon.wait();
}

/// Своя сессионная шина на время теста. `--nofork` держит демон нашим
/// потомком, поэтому он уходит вместе с тестом даже при панике.
fn start_session_bus() -> Option<Child> {
    let mut child = Command::new("dbus-daemon")
        .args(["--session", "--print-address", "--nofork"])
        .stdout(Stdio::piped())
        .spawn()
        .ok()?;

    let stdout = child.stdout.take()?;
    let mut address = String::new();
    BufReader::new(stdout).read_line(&mut address).ok()?;
    std::env::set_var("DBUS_SESSION_BUS_ADDRESS", address.trim());
    Some(child)
}

fn wait_for<T>(limit: Duration, mut probe: impl FnMut() -> Option<T>) -> Option<T> {
    let deadline = Instant::now() + limit;
    while Instant::now() < deadline {
        if let Some(value) = probe() {
            return Some(value);
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    probe()
}
