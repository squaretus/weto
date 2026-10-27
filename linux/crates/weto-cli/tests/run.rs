//! `weto run`: замок, отказ при запущенном приложении, перечитывание
//! настроек, лог — и живой процесс целиком: старт, статус, правка из второго
//! процесса, штатный выход по SIGTERM.

mod support;

use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use support::{process, FakeRegistry};
use weto_cli::context::Identity;
use weto_cli::log::{LogSink, LoggingReporter};
use weto_cli::run::{app_conflict, app_is_running, scope_text, AppConflict, LockError, RunLock};
use weto_cli::store::{Reload, Store, WatchedSettings};
use weto_config::journal::KillContext;
use weto_core::process::{MatchBasis, MatchedProcess};
use weto_guard::controller::KillReporting;

// --- замок и приложение рядом ----------------------------------------------------

/// Второй держатель получает отказ с pid первого — его и печатает `run`.
#[test]
fn the_run_lock_admits_one_holder_and_names_it() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("state/run.lock");

    let first = RunLock::acquire(&path).ok().expect("первый берёт замок");
    match RunLock::acquire(&path) {
        Err(LockError::Held(Some(pid))) => assert_eq!(pid, std::process::id() as i32),
        Err(LockError::Held(None)) => panic!("держатель не назван"),
        Err(LockError::Io(error)) => panic!("{error}"),
        Ok(_) => panic!("замок взят дважды"),
    }

    drop(first);
    // Соседние тесты порождают процессы, и копия дескриптора живёт в потомке
    // между fork и exec — замок там держится ещё миг. Ждём его, а не гадаем.
    let started = Instant::now();
    let mut again = RunLock::acquire(&path);
    while again.is_err() && started.elapsed() < Duration::from_secs(2) {
        std::thread::sleep(Duration::from_millis(20));
        again = RunLock::acquire(&path);
    }
    assert!(again.is_ok(), "отпущенный замок берётся снова");
}

#[test]
fn a_process_from_the_app_directory_is_the_app() {
    let data = Path::new("/home/u/.local/share/weto");
    let registry = FakeRegistry::with(vec![
        process(10, "/usr/bin/bash"),
        process(11, "/home/u/.local/share/weto-cli/x"),
        process(12, "/home/u/.local/share/weto/0.4.0/weto"),
    ]);

    assert_eq!(app_is_running(&registry, data, 1), Some(12));
    assert_eq!(app_is_running(&registry, data, 12), None, "себя не считаем");
    assert_eq!(
        app_is_running(
            &FakeRegistry::with(vec![process(11, "/home/u/.local/share/weto-cli/x")]),
            data,
            1
        ),
        None,
        "каталог weto-cli — не приложение"
    );
}

/// Охрана от root стережёт цели всех пользователей — и приложение ищет у всех.
#[test]
fn the_app_of_another_user_counts_too() {
    let root_data = Path::new("/root/.local/share/weto");
    let registry = FakeRegistry::with(vec![
        process(10, "/usr/bin/bash"),
        process(21, "/home/alice/.local/share/weto/0.4.0/weto"),
    ]);

    assert_eq!(app_is_running(&registry, root_data, 1), Some(21));
}

/// Признак приложения — путь под `*/.local/share/weto/`, и создать его может любой
/// пользователь. Охрану всей машины такой процесс не выключает: она стартует
/// и предупреждает. Пользовательская охрана рядом со своим приложением не стартует.
#[test]
fn a_whole_machine_guard_never_refuses_because_of_an_app() {
    assert_eq!(app_conflict(true, Some(21)), AppConflict::Warn(21));
    assert_eq!(app_conflict(false, Some(21)), AppConflict::Refuse(21));
    assert_eq!(app_conflict(true, None), AppConflict::None);
    assert_eq!(app_conflict(false, None), AppConflict::None);
}

/// Строка старта называет, чью охрану ведёт процесс: машины или пользователя.
#[test]
fn the_start_line_names_whose_guard_this_is() {
    let mut identity = Identity {
        is_root: true,
        user: "root".to_string(),
        executable: Err(String::new()),
        user_unit_dir: "/root/.config/systemd/user".into(),
        system_unit_dir: "/etc/systemd/system".into(),
    };
    assert_eq!(scope_text(&identity), "вся машина");

    identity.is_root = false;
    identity.user = "square".to_string();
    assert_eq!(scope_text(&identity), "пользователь square");
}

// --- перечитывание настроек -----------------------------------------------------------

/// Охрана перечитывает файл по отметке, а не каждый такт: без правки — ни разбора,
/// ни новостей; правка из другого процесса доходит; испорченный файл оставляет
/// охрану на прежних настройках.
#[test]
fn the_running_guard_rereads_the_settings_when_the_file_changes() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("config.toml");
    let store = Store::new(path.clone());
    store
        .edit(|s| {
            s.blocked_countries = vec!["RU".to_string()];
            Ok::<_, ()>(())
        })
        .unwrap()
        .unwrap();
    let watched = WatchedSettings::open(path.clone()).unwrap();

    assert_eq!(watched.reload_if_changed(), Reload::Unchanged);

    store
        .edit(|s| {
            s.set_vpn_tunnel(Some("wg0".to_string()));
            Ok::<_, ()>(())
        })
        .unwrap()
        .unwrap();
    assert_eq!(watched.reload_if_changed(), Reload::Reloaded);
    assert_eq!(watched.current().vpn_tunnel.as_deref(), Some("wg0"));
    assert_eq!(watched.current().revision, 2);
    assert_eq!(watched.reload_if_changed(), Reload::Unchanged);

    std::fs::write(&path, "targets = [[[").unwrap();
    assert!(matches!(watched.reload_if_changed(), Reload::Failed(_)));
    assert_eq!(
        watched.current().vpn_tunnel.as_deref(),
        Some("wg0"),
        "испорченный файл не отнимает настроек"
    );
    assert_eq!(
        watched.reload_if_changed(),
        Reload::Unchanged,
        "ошибка не печатается каждый такт"
    );
}

// --- лог --------------------------------------------------------------------------

#[derive(Default)]
struct Silent;

impl KillReporting for Silent {
    fn report(&self, _: &[MatchedProcess], _: &[MatchedProcess], _: &KillContext) {}
}

fn matched(pid: i32, name: &str) -> MatchedProcess {
    MatchedProcess {
        pid,
        target_name: name.to_string(),
        target_entry: name.to_string(),
        parent_pid: 1,
        executable_path: format!("/usr/bin/{name}"),
        matched_by: MatchBasis::Rule,
    }
}

/// Пауза и завершение — строкой с именами, pid и причиной: уведомлений
/// рабочего стола у терминальной версии нет.
#[test]
fn pauses_and_kills_are_logged_with_names_pids_and_reason() {
    let lines = Arc::new(Mutex::new(Vec::<String>::new()));
    let sink: LogSink = {
        let lines = lines.clone();
        Arc::new(move |text: &str| lines.lock().unwrap().push(text.to_string()))
    };
    let reporter = LoggingReporter {
        inner: Silent,
        log: sink,
    };
    let context = KillContext {
        reason: "VPN-туннель wg0 не поднят".to_string(),
        ..KillContext::default()
    };

    reporter.paused(&[matched(10, "claude"), matched(11, "claude")], &context);
    reporter.report(&[matched(12, "codex")], &[], &context);
    reporter.pause_resolved("возобновлено проверкой", None, &context);

    assert_eq!(
        *lines.lock().unwrap(),
        [
            "на паузе: claude ×2 (pid 10, 11) — VPN-туннель wg0 не поднят",
            "завершены: codex (pid 12) — VPN-туннель wg0 не поднят",
            "исход паузы: возобновлено проверкой",
        ]
    );
}

// --- живой процесс ----------------------------------------------------------------

/// Живой процесс — под обычным пользователем. От root `weto` берёт системное
/// хранилище (`/etc/weto`, `/var/lib/weto`), и временный `$HOME` его бы
/// не изолировал; в контейнере тесты идут под root, поэтому бинарник
/// запускается под `nobody`, а временный дом отдаётся ему.
const NOBODY: u32 = 65534;

fn running_as_root() -> bool {
    // SAFETY: geteuid не имеет побочных эффектов.
    unsafe { libc::geteuid() == 0 }
}

fn as_regular_user(command: &mut Command) -> &mut Command {
    use std::os::unix::process::CommandExt;
    if running_as_root() {
        command.uid(NOBODY).gid(NOBODY);
    }
    command
}

/// Отдать дерево `nobody`: под ним живёт бинарник, и писать в свой дом
/// он обязан сам.
fn give_away(path: &Path) {
    if !running_as_root() {
        return;
    }
    std::os::unix::fs::chown(path, Some(NOBODY), Some(NOBODY)).unwrap();
    if path.is_dir() {
        for entry in std::fs::read_dir(path).unwrap() {
            give_away(&entry.unwrap().path());
        }
    }
}

struct Live {
    home: tempfile::TempDir,
}

impl Live {
    fn new() -> Live {
        let home = tempfile::tempdir().unwrap();
        give_away(home.path());
        Live { home }
    }

    fn command(&self, args: &[&str]) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_weto-cli"));
        as_regular_user(&mut command);
        command
            .args(args)
            .env("HOME", self.home.path())
            .env_remove("XDG_CONFIG_HOME")
            .env_remove("XDG_STATE_HOME")
            .env_remove("XDG_DATA_HOME")
            .env_remove("XDG_CACHE_HOME");
        command
    }

    fn output(&self, args: &[&str]) -> std::process::Output {
        self.command(args).output().unwrap()
    }

    fn spawn_run(&self) -> Child {
        self.command(&["run"])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap()
    }

    fn status_file(&self) -> std::path::PathBuf {
        self.home.path().join(".local/state/weto-cli/status.json")
    }

    /// Дождаться условия, не дольше `limit`.
    fn wait_for(&self, limit: Duration, mut condition: impl FnMut() -> bool) -> bool {
        let started = Instant::now();
        while started.elapsed() < limit {
            if condition() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        condition()
    }
}

fn terminate(child: &Child) {
    // SAFETY: SIGTERM своему дочернему процессу.
    unsafe {
        libc::kill(child.id() as i32, libc::SIGTERM);
    }
}

/// Целиком: старт, статус, второй `run` с отказом, правка из второго процесса,
/// доходящая до работающей охраны, и штатный выход по SIGTERM с уборкой статуса.
#[test]
fn a_live_run_reports_status_rereads_settings_and_exits_on_sigterm() {
    let live = Live::new();
    let mut child = live.spawn_run();

    assert!(
        live.wait_for(Duration::from_secs(10), || live.status_file().exists()),
        "статус не появился"
    );
    let status = live.output(&["status"]);
    assert_eq!(status.status.code(), Some(0), "{:?}", status);
    let text = String::from_utf8_lossy(&status.stdout);
    assert!(text.starts_with("Охрана:   Охрана выключена"), "{text}");

    let second = live.output(&["run"]);
    assert_eq!(second.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&second.stderr)
        .contains(&format!("охрана уже запущена (pid {})", child.id())));

    // Правка из второго процесса: работающая охрана видит её по отметке файла.
    assert_eq!(
        live.output(&["timeout", "set", "10"]).status.code(),
        Some(0)
    );
    assert!(
        live.wait_for(Duration::from_secs(5), || {
            let json = live.output(&["status", "--json"]);
            serde_json::from_slice::<serde_json::Value>(&json.stdout)
                .map(|value| value["pauseCeilingSeconds"] == 600)
                .unwrap_or(false)
        }),
        "правка не дошла до работающей охраны"
    );

    terminate(&child);
    let exit = child.wait().unwrap();
    assert_eq!(exit.code(), Some(0));
    assert!(!live.status_file().exists(), "статус убран на выходе");
    let mut log = String::new();
    use std::io::Read;
    child
        .stdout
        .take()
        .unwrap()
        .read_to_string(&mut log)
        .unwrap();
    assert!(
        log.contains(&format!(
            "охрана запущена (pid {}, пользователь ",
            child.id()
        )),
        "{log}"
    );
    assert!(log.contains("); weto dev; настройки: "), "{log}");
    assert!(log.contains("настройки перечитаны"), "{log}");
    assert!(log.contains("SIGTERM: штатный выход"), "{log}");
    assert!(log.contains("охрана остановлена"), "{log}");

    let after = live.output(&["status"]);
    assert_eq!(after.status.code(), Some(3));
}

/// Приложение Weto запущено — вторая охрана над теми же целями не стартует.
#[test]
fn run_refuses_while_the_weto_app_is_running() {
    let live = Live::new();
    // Каталог данных — свой, через `XDG_DATA_HOME`, а не `~/.local/share`:
    // живая охрана соседнего теста ищет приложение под любым
    // `*/.local/share/weto/` и приняла бы этот процесс за запущенное приложение.
    let data_home = live.home.path().join("data");
    let app_dir = data_home.join("weto/0.4.0");
    std::fs::create_dir_all(&app_dir).unwrap();
    let app = app_dir.join("weto");
    std::fs::copy("/bin/sleep", &app).unwrap();
    give_away(live.home.path());
    // Под тем же пользователем, что `weto`: чужой `/proc/<pid>/exe` он не прочтёт.
    let mut fake_app = as_regular_user(&mut Command::new(&app))
        .arg("30")
        .spawn()
        .unwrap();

    let output = live
        .command(&["run"])
        .env("XDG_DATA_HOME", &data_home)
        .output()
        .unwrap();

    let _ = fake_app.kill();
    let _ = fake_app.wait();
    assert_eq!(output.status.code(), Some(1));
    let error = String::from_utf8_lossy(&output.stderr);
    assert!(
        error.contains(
            "запущено приложение Weto: две охраны над одними целями мешают друг другу — \
             закройте приложение"
        ),
        "{error}"
    );
    assert!(!live.status_file().exists());
}
