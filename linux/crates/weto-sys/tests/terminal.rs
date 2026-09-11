//! Подъём терминала проверяется на настоящей шине и настоящем `/proc`.
//!
//! Подменять здесь нечего: тест поднимает свою сессионную шину, сам становится
//! приложением с интерфейсом `org.freedesktop.Application`, порождает потомка —
//! и спрашивает границу, кто держит терминал этого потомка. Ответом обязан быть
//! сам тест: он и есть ближайший предок, владеющий именем на шине, — ровно так
//! под живым рабочим столом находится `gnome-terminal-server`, которого нет
//! в индексе ярлыков.
//!
//! Чего тест не проверяет — что окно и правда поднялось: это видно только
//! глазами на живом рабочем столе (`linux/docs/manual-ui-check.md`). Проверяется
//! то, что можно: кого weto выбрал, каким именем и что вызов дошёл.
//!
//! Всё одним тестом намеренно: адрес шины живёт в переменной окружения, общей
//! на все потоки `cargo test`.

use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use weto_sys::desktop_entries::DesktopIndex;
use weto_sys::process_registry::{ProcRegistry, ProcessRegistryReading};
use weto_sys::terminal::{DesktopTerminalActivator, TerminalActivating};

const NAME: &str = "com.weto.FakeTerminal";
const PATH: &str = "/com/weto/FakeTerminal";

struct FakeTerminal {
    activated: Arc<AtomicBool>,
}

#[zbus::interface(name = "org.freedesktop.Application")]
impl FakeTerminal {
    fn activate(&self, _platform_data: HashMap<String, zbus::zvariant::OwnedValue>) {
        self.activated.store(true, Ordering::SeqCst);
    }
}

#[test]
fn the_ancestor_owning_a_bus_name_is_the_terminal_and_it_is_raised() {
    let Some(mut daemon) = start_session_bus() else {
        eprintln!("dbus-daemon не найден — подъём терминала проверить нечем, пропускаю");
        return;
    };

    let activated = Arc::new(AtomicBool::new(false));
    let _server = zbus::blocking::connection::Builder::session()
        .expect("сессионная шина")
        .name(NAME)
        .expect("имя приложения")
        .serve_at(
            PATH,
            FakeTerminal {
                activated: activated.clone(),
            },
        )
        .expect("объект приложения")
        .build()
        .expect("поддельный терминал");

    let mut child = Command::new("sleep")
        .arg("30")
        .spawn()
        .expect("потомок не запустился");
    let target = child.id() as i32;

    let processes = ProcRegistry::new().snapshot();
    // Индекс ярлыков пустой намеренно: тестовый бинарник эмулятором себя
    // не объявляет, и находиться он обязан по имени на шине.
    let activator = DesktopTerminalActivator::with_index(DesktopIndex::default());

    let host = activator
        .locate(target, &processes)
        .expect("терминал не нашёлся");

    assert_eq!(
        host.pid,
        std::process::id() as i32,
        "терминалом обязан быть ближайший предок с именем на шине"
    );
    assert_eq!(host.bus_name.as_deref(), Some(NAME));
    assert_eq!(host.object_path.as_deref(), Some(PATH));
    assert!(host.can_activate());

    assert!(activator.activate(&host), "вызов обязан уйти");
    let raised = wait_for(Duration::from_secs(5), || {
        activated.load(Ordering::SeqCst).then_some(())
    });
    assert!(raised.is_some(), "Activate не дошёл до приложения");

    // Процесс без предков поднимать нечем, и выдумывать ответ нельзя:
    // так ведёт себя цель, запущенная не из терминала вовсе.
    assert!(
        activator.locate(1, &processes).is_none(),
        "у процесса без предков терминала нет"
    );

    let _ = child.kill();
    let _ = child.wait();
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
