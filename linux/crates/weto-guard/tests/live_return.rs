//! Живая проверка на настоящих tmux и GNU screen: настоящие обход, сигналы, режим терминала
//! и ввод `fg`. Порт `macos/Tests/WetoSharedTests/LiveTmuxReturnTests.swift`.
//!
//! Сервер каждого сразу продолжает остановленный шелл, тот забирает терминал у стоящей цели,
//! и SIGCONT оставляет её в фоне: интерфейс нарисован, а клавиши идут шеллу. Моки этого
//! не покажут.
//!
//! Запускается руками и не от root (от root возврат отказывает, ничего не запуская):
//! `WETO_LIVE_TMUX=1 WETO_LIVE_SCREEN=1 WETO_LIVE_SHELL=/usr/bin/zsh <бинарник теста>`.
//! В CI и контейнере разработки ни tmux, ни screen нет.

use std::collections::HashSet;
use std::process::Command;
use std::time::Duration;

use weto_core::pause_plan::shell_holding_terminal;
use weto_core::process::{TargetKind, TargetRule};
use weto_guard::enforcer::ProcessEnforcer;
use weto_sys::process_registry::{ProcRegistry, ProcessRegistryReading};
use weto_sys::process_signaler::ProcessSignaler;
use weto_sys::terminal_return::{MultiplexerForegroundReturner, TerminalForegroundReturning};

const RAW_PROBE: &str = r#"
#include <stdio.h>
#include <termios.h>
#include <unistd.h>
#include <sys/select.h>
int main(int c, char **v) {
    FILE *o = fopen(v[1], "a"); setvbuf(o, NULL, _IONBF, 0);
    struct termios t; tcgetattr(0, &t); cfmakeraw(&t); tcsetattr(0, TCSANOW, &t);
    for (;;) {
        fd_set r; FD_ZERO(&r); FD_SET(0, &r);
        struct timeval tv = {0, 200000};
        if (select(1, &r, NULL, NULL, &tv) > 0) {
            char b[64]; ssize_t n = read(0, b, sizeof b);
            if (n > 0) { fprintf(o, "got:%.*s\n", (int)n, b); }
        }
    }
}
"#;

fn sh(command: &str) -> String {
    let output = Command::new("/bin/bash")
        .args(["-c", command])
        .output()
        .expect("bash запустился");
    let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
    text.push_str(&String::from_utf8_lossy(&output.stderr));
    text.trim().to_string()
}

fn wait(milliseconds: u64) {
    std::thread::sleep(Duration::from_millis(milliseconds));
}

/// Закрывает сервер даже при упавшей проверке.
struct Server(String);

impl Drop for Server {
    fn drop(&mut self) {
        sh(&self.0);
    }
}

fn live_shell() -> String {
    std::env::var("WETO_LIVE_SHELL").unwrap_or_else(|_| "/bin/bash".to_string())
}

#[test]
fn a_paused_target_under_tmux_comes_back_with_the_keyboard() {
    if std::env::var("WETO_LIVE_TMUX").as_deref() != Ok("1") {
        return;
    }
    let tmux = format!("tmux -L wetolive{} -f /dev/null", std::process::id());
    let _server = Server(format!("{tmux} kill-server"));
    sh(&format!(
        "SHELL={} {tmux} new-session -d -x 120 -y 30",
        live_shell()
    ));
    wait(1_500);
    paused_target_comes_back(
        &|text, enter| {
            sh(&format!("{tmux} send-keys -l '{text}'"));
            if enter {
                sh(&format!("{tmux} send-keys Enter"));
            }
        },
        &format!("{tmux} send-keys -l $'\\e[<35;173;10M'"),
        &format!("{tmux} capture-pane -p"),
    );
}

#[test]
fn a_paused_target_under_screen_comes_back_with_the_keyboard() {
    if std::env::var("WETO_LIVE_SCREEN").as_deref() != Ok("1") {
        return;
    }
    let session = format!("wetolive{}", std::process::id());
    let _server = Server(format!("screen -S {session} -X quit"));
    sh(&format!("screen -dmS {session} {}", live_shell()));
    wait(1_500);
    let dump = format!("{}/screen.txt", std::env::temp_dir().display());
    paused_target_comes_back(
        &|text, enter| {
            let end = if enter { "\\n" } else { "" };
            sh(&format!("screen -S {session} -X stuff '{text}'$'{end}'"));
        },
        &format!("screen -S {session} -X stuff $'\\e[<35;173;10M'"),
        &format!("screen -S {session} -X hardcopy {dump}; sleep 0.2; cat {dump}"),
    );
}

/// `type_keys` вводит текст в единственное окно сервера, как с клавиатуры, с Enter или без.
/// `mouse_report` — команда, дающая один отчёт мыши, `read_screen` — показывающая экран.
fn paused_target_comes_back(type_keys: &dyn Fn(&str, bool), mouse_report: &str, read_screen: &str) {
    let home = tempfile::tempdir().expect("временный каталог");
    let dir = home.path().to_string_lossy().into_owned();
    let out = format!("{dir}/probe.out");
    let probe = format!("{dir}/rawprobe");
    std::fs::write(format!("{dir}/rawprobe.c"), RAW_PROBE).unwrap();
    assert_eq!(sh(&format!("cc -o {probe} {dir}/rawprobe.c")), "");

    type_keys(&format!("{probe} {out}"), true);

    let tty = || {
        ProcRegistry::new()
            .snapshot()
            .iter()
            .find(|process| process.executable_path == probe)
            .and_then(|process| std::fs::read_link(format!("/proc/{}/fd/0", process.pid)).ok())
            .map(|path| path.to_string_lossy().into_owned())
    };
    let is_raw = || tty().is_some_and(|tty| sh(&format!("stty -a -F {tty}")).contains("-icanon"));
    for _ in 0..150 {
        if is_raw() {
            break;
        }
        wait(100);
    }
    assert!(is_raw(), "зонд обязан перевести терминал в сырой режим");
    wait(200);

    let rules = vec![TargetRule::new(
        &probe,
        "rawprobe",
        TargetKind::Binary,
        &probe,
        &[&probe],
    )];
    let enforcer = ProcessEnforcer::new(
        Box::new(ProcRegistry::new()),
        Box::new(ProcessSignaler::new()),
        home.path().join("stopped.json"),
    );

    let paused = enforcer.pause(&enforcer.scan(&rules));
    assert_eq!(
        paused.plan.foreground_roots.len(),
        1,
        "цель держала терминал"
    );
    assert_eq!(paused.plan.shells.len(), 1, "шелл входит в план");
    wait(1_000);

    for _ in 0..3 {
        enforcer.resume(Some(&enforcer.scan(&rules)), &HashSet::new());
        enforcer.restore_terminal_modes(Some(&enforcer.scan(&rules)));
        wait(300);
    }

    // Ровно тот призрак: цель идёт, терминал у шелла.
    let waiting = enforcer.awaiting_foreground(None);
    assert_eq!(waiting.len(), 1, "цель обязана ждать возврата");

    // Набранное в строке шелла не должно склеиться с `fg`. Цель включила отслеживание мыши
    // и выключить его не может, поэтому в строку без конца идут отчёты, в том числе между
    // любыми двумя нашими командами. Точки с запятой в них — разделители команд.
    type_keys("half typed", false);
    let mut mouse = Command::new("/bin/bash")
        .args(["-c", &format!("while :; do {mouse_report}; done")])
        .spawn()
        .expect("поток отчётов мыши");
    wait(500);

    let processes = ProcRegistry::new().snapshot();
    let target = processes
        .iter()
        .find(|process| process.pid == waiting[0])
        .expect("цель жива");
    let holder = shell_holding_terminal(target, &processes).expect("терминал у шелла");
    MultiplexerForegroundReturner
        .return_to_foreground(target, holder, &processes)
        .expect("возврат настоящим кодом");

    wait(300);
    enforcer.restore_terminal_modes(None);
    mouse.kill().expect("поток отчётов мыши");
    mouse.wait().expect("поток отчётов мыши");

    let screen = sh(read_screen);
    assert!(
        !screen.contains("not found"),
        "строка выполнилась как команды:\n{screen}"
    );
    assert!(
        enforcer.awaiting_foreground(None).is_empty(),
        "цель снова впереди, режим возвращён:\n{screen}"
    );
    assert!(is_raw(), "терминал обязан быть в сыром режиме цели");

    type_keys("x", false);
    wait(700);
    let seen = std::fs::read_to_string(&out).unwrap_or_default();
    assert!(
        seen.contains("got:x"),
        "клавиша обязана дойти до цели: {seen:?}"
    );
}
