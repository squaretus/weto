//! Сервис systemd: текст юнита и разговор с `systemctl`/`loginctl` через
//! подменённую границу внешних команд.

mod support;

use std::path::{Path, PathBuf};

use support::Bench;
use weto_cli::service::{is_build_output, linger_disabled, unit_text};

#[test]
fn the_user_unit_runs_the_binary_and_stops_gracefully() {
    assert_eq!(
        unit_text(Path::new("/opt/weto/weto"), false),
        "[Unit]\n\
         Description=weto — охрана целей по VPN\n\
         After=network-online.target\n\
         \n\
         [Service]\n\
         Type=simple\n\
         ExecStart=/opt/weto/weto run\n\
         Restart=on-failure\n\
         RestartSec=2\n\
         KillSignal=SIGTERM\n\
         TimeoutStopSec=15\n\
         \n\
         [Install]\n\
         WantedBy=default.target\n"
    );
}

/// Системный юнит — под multi-user и без `HOME`: от root пути фиксированы
/// (`/etc/weto`, `/var/lib/weto`) и берутся по uid, а не по окружению.
#[test]
fn the_root_unit_is_wanted_by_multi_user_and_needs_no_home() {
    let text = unit_text(Path::new("/usr/local/bin/weto"), true);

    assert!(text.contains("ExecStart=/usr/local/bin/weto run\n"));
    assert!(text.contains("WantedBy=multi-user.target\n"));
    assert!(!text.contains("Environment="));
}

/// systemd делит `ExecStart` по пробелам: путь с пробелом — в кавычках.
#[test]
fn a_path_with_a_space_is_quoted() {
    let text = unit_text(Path::new("/opt/my tools/weto"), false);

    assert!(text.contains("ExecStart=\"/opt/my tools/weto\" run\n"));
}

#[test]
fn a_binary_inside_a_build_directory_is_recognised() {
    assert!(is_build_output(Path::new(
        "/home/u/weto/linux/target/release/weto-cli"
    )));
    assert!(is_build_output(Path::new("/x/macos/.build/cli/weto-cli")));
    assert!(!is_build_output(Path::new("/usr/local/bin/weto")));
}

#[test]
fn linger_is_read_from_loginctl() {
    assert!(linger_disabled("Linger=no\n"));
    assert!(!linger_disabled("Linger=yes"));
    assert!(!linger_disabled(""));
}

/// Пользовательская установка: юнит в `~/.config/systemd/user`, `--user` у каждой
/// команды, подсказка про linger, если он выключен.
#[test]
fn a_user_install_writes_the_unit_enables_it_and_hints_at_linger() {
    let bench = Bench::new();
    bench
        .commands
        .answers("loginctl show-user square -p Linger", true, "Linger=no");
    bench
        .commands
        .answers("systemctl --user is-active", false, "inactive");

    let output = bench.run(&["service", "install"]);

    assert_eq!(output.code, 0, "{}", output.err);
    let unit = bench.home.path().join(".config/systemd/user/weto.service");
    assert_eq!(
        std::fs::read_to_string(&unit).unwrap(),
        unit_text(Path::new("/opt/weto/weto"), false)
    );
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(
        std::fs::metadata(&unit).unwrap().permissions().mode() & 0o777,
        0o644
    );
    assert_eq!(
        bench.commands.calls(),
        [
            "systemctl --user daemon-reload",
            "systemctl --user enable weto.service",
            "systemctl --user is-active weto.service",
            "systemctl --user start weto.service",
            "loginctl show-user square -p Linger",
        ]
    );
    assert!(
        output.out.starts_with(&format!(
            "сервис установлен: {}\n\
             охрана запущена: weto.service; лог — journalctl --user -u weto -f\n",
            unit.display()
        )),
        "{}",
        output.out
    );
    assert!(output.out.contains("loginctl enable-linger square"));
}

/// Установщик зовёт `service install` и поверх прежней установки: юнит
/// переписывается, а запущенный сервис перезапускается на новом бинарнике.
#[test]
fn installing_over_a_running_service_restarts_it() {
    let bench = Bench::new();
    bench
        .commands
        .answers("systemctl --user is-active", true, "active");

    let output = bench.run(&["service", "install"]);

    assert_eq!(output.code, 0, "{}", output.err);
    let calls = bench.commands.calls();
    assert!(calls.contains(&"systemctl --user restart weto.service".to_string()));
    assert!(!calls.iter().any(|call| call.contains(" start ")));
    assert_eq!(output.out, "Сервис обновлён и перезапущен: weto.service\n");

    // Второй раз — то же самое: идемпотентно, код 0.
    assert_eq!(bench.run(&["service", "install"]).code, 0);
}

#[test]
fn a_root_install_uses_the_system_manager() {
    let bench = Bench::new().run_by_root();

    let output = bench.run(&["service", "install"]);

    assert_eq!(output.code, 0, "{}", output.err);
    assert!(bench
        .home
        .path()
        .join("system/etc/systemd/system/weto.service")
        .exists());
    assert_eq!(
        bench.commands.calls(),
        [
            "systemctl daemon-reload",
            "systemctl enable weto.service",
            "systemctl is-active weto.service",
            "systemctl start weto.service",
        ]
    );
    assert!(!output.out.contains("linger"));
    assert!(output
        .out
        .ends_with("охрана запущена: weto.service; лог — journalctl -u weto -f\n"));
}

#[test]
fn installing_from_a_build_directory_warns() {
    let mut bench = Bench::new();
    bench.ctx.identity.executable = Ok(PathBuf::from("/repo/linux/target/debug/weto-cli"));

    let output = bench.run(&["service", "install"]);

    assert_eq!(output.code, 0);
    assert_eq!(
        output.err,
        "бинарник лежит в каталоге сборки (/repo/linux/target/debug/weto-cli) — сервис \
         сломается при пересборке; положите weto на постоянное место и установите сервис оттуда\n"
    );
}

#[test]
fn a_refused_systemctl_fails_the_install() {
    let bench = Bench::new();
    bench.commands.answers("systemctl --user enable", false, "");

    let output = bench.run(&["service", "install"]);

    assert_eq!(output.code, 1);
}

#[test]
fn uninstall_stops_disables_and_removes_the_unit() {
    let bench = Bench::new();
    bench.run(&["service", "install"]);
    let unit = bench.home.path().join(".config/systemd/user/weto.service");
    assert!(unit.exists());

    let output = bench.run(&["service", "uninstall"]);

    assert_eq!(output.code, 0, "{}", output.err);
    assert!(!unit.exists());
    let calls = bench.commands.calls();
    assert!(calls.contains(&"systemctl --user disable --now weto.service".to_string()));
    assert_eq!(calls.last().unwrap(), "systemctl --user daemon-reload");

    assert_eq!(
        bench.run(&["service", "uninstall"]).code,
        1,
        "снимать нечего"
    );
}

#[test]
fn service_status_names_the_file_and_the_state() {
    let bench = Bench::new();
    bench
        .commands
        .answers("systemctl --user is-active", false, "inactive");

    let before = bench.run(&["service", "status"]);
    assert_eq!(before.out, "Сервис: не установлен\nСостояние: inactive\n");

    bench.run(&["service", "install"]);
    let after = bench.run(&["service", "status"]);
    assert!(
        after.out.starts_with("Сервис: установлен ("),
        "{}",
        after.out
    );
}

/// Не-root при системной установке спрашивает про охрану машины: системный
/// юнит и `systemctl` без `--user`.
#[test]
fn service_status_of_a_user_on_a_system_install_shows_the_system_unit() {
    let root = Bench::new().run_by_root();
    root.run(&["service", "install"]);
    let mut user = Bench::new();
    user.ctx.system_paths = root.ctx.system_paths.clone();
    user.ctx.identity.system_unit_dir = root.ctx.identity.system_unit_dir.clone();
    user.commands.answers("systemctl is-active", true, "active");

    let output = user.run(&["service", "status"]);

    assert_eq!(output.code, 0);
    assert!(output
        .out
        .contains("system/etc/systemd/system/weto.service"));
    assert!(
        output.out.ends_with("Состояние: active\n"),
        "{}",
        output.out
    );
}
