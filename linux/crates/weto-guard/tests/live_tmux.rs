//! Живая проверка на настоящем tmux: настоящие обход, сигналы, режим терминала и ввод `fg`.
//! Порт `macos/Tests/WetoSharedTests/LiveTmuxReturnTests.swift`.
//!
//! Под tmux шелл панели забирает терминал у стоящей цели, и SIGCONT оставляет её в фоне:
//! интерфейс нарисован, а клавиши идут шеллу. Моки этого не покажут.
//!
//! Запускается руками и не от root (от root возврат отказывает, ничего не запуская):
//! `WETO_LIVE_TMUX=1 WETO_LIVE_SHELL=/usr/bin/zsh <бинарник теста>`.
//! В CI и контейнере разработки tmux нет.

use std::collections::HashSet;
use std::process::Command;
use std::time::Duration;

use weto_core::pause_plan::shell_holding_terminal;
use weto_core::process::{TargetKind, TargetRule};
use weto_guard::enforcer::ProcessEnforcer;
use weto_sys::process_registry::{ProcRegistry, ProcessRegistryReading};
use weto_sys::process_signaler::ProcessSignaler;
use weto_sys::terminal_return::{TerminalForegroundReturning, TmuxForegroundReturner};

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

struct Server(String);

impl Drop for Server {
    fn drop(&mut self) {
        sh(&format!("{} kill-server", self.0));
    }
}

#[test]
fn a_paused_target_comes_back_with_the_keyboard() {
    if std::env::var("WETO_LIVE_TMUX").as_deref() != Ok("1") {
        return;
    }
    let home = tempfile::tempdir().expect("временный каталог");
    let dir = home.path().to_string_lossy().into_owned();
    let out = format!("{dir}/probe.out");
    let probe = format!("{dir}/rawprobe");
    std::fs::write(format!("{dir}/rawprobe.c"), RAW_PROBE).unwrap();
    assert_eq!(sh(&format!("cc -o {probe} {dir}/rawprobe.c")), "");

    let shell = std::env::var("WETO_LIVE_SHELL").unwrap_or_else(|_| "/bin/bash".to_string());
    let tmux = format!("tmux -L wetolive{} -f /dev/null", std::process::id());
    let _server = Server(tmux.clone());
    sh(&format!("SHELL={shell} {tmux} new-session -d -x 120 -y 30"));
    wait(1_500);
    sh(&format!("{tmux} send-keys '{probe} {out}' Enter"));

    let pane_tty = sh(&format!("{tmux} display -p '#{{pane_tty}}'"));
    let is_raw = || sh(&format!("stty -a -F {pane_tty}")).contains("-icanon");
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

    // Набранное в строке шелла не должно склеиться с `fg`.
    sh(&format!("{tmux} send-keys 'half typed'"));
    wait(300);

    let processes = ProcRegistry::new().snapshot();
    let target = processes
        .iter()
        .find(|process| process.pid == waiting[0])
        .expect("цель жива");
    let holder = shell_holding_terminal(target, &processes).expect("терминал у шелла");
    TmuxForegroundReturner
        .return_to_foreground(target, holder, &processes)
        .expect("возврат настоящим кодом");

    wait(300);
    enforcer.restore_terminal_modes(None);

    assert!(
        enforcer.awaiting_foreground(None).is_empty(),
        "цель снова впереди, режим возвращён"
    );
    assert!(is_raw(), "терминал обязан быть в сыром режиме цели");

    sh(&format!("{tmux} send-keys x"));
    wait(700);
    let seen = std::fs::read_to_string(&out).unwrap_or_default();
    assert!(
        seen.contains("got:x"),
        "клавиша обязана дойти до цели: {seen:?}"
    );
    println!(
        "[live] панель:\n{}",
        sh(&format!("{tmux} capture-pane -p | grep -v '^$' | tail -6"))
    );
}
