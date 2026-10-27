//! Охрана всей машины: от root — системное хранилище (`/etc/weto`,
//! `/var/lib/weto`), не-root при системной установке — подсказка про sudo.
//!
//! Корень стенда подменяет `/`: системные каталоги лежат в его `system/`.

mod support;

use std::os::unix::fs::PermissionsExt;
use std::time::Duration;

use support::{now, Bench, FakeProcesses};
use weto_cli::status::{self, PhaseStatus, StatusFile, VpnStatus};

fn mode(path: &std::path::Path) -> u32 {
    std::fs::metadata(path).unwrap().permissions().mode() & 0o777
}

/// Правки от root ложатся в `/etc/weto`: настройки читаются без sudo (`0644`),
/// каталоги — `0755`, токен — `0600`, а каталог при нём не сужается.
#[test]
fn root_writes_the_system_storage() {
    let bench = Bench::new().run_by_root();

    assert_eq!(bench.run(&["blacklist", "add", "RU"]).code, 0);
    assert_eq!(bench.run(&["token", "set", "secret"]).code, 0);

    let system = &bench.ctx.system_paths;
    let settings = system.settings_file();
    assert!(settings.ends_with("system/etc/weto/config.toml"));
    assert_eq!(mode(&settings), 0o644);
    assert_eq!(mode(&system.config_dir), 0o755);
    assert_eq!(mode(&system.state_dir), 0o755);
    assert_eq!(mode(&system.token_file()), 0o600);
    assert!(
        !bench.home.path().join(".config/weto-cli").exists(),
        "от root — только системное хранилище"
    );
}

/// Каталог `/etc/weto` — признак системной установки, и заводит его только
/// команда, которая пишет: `sudo weto version` машину системной не делает.
#[test]
fn root_reading_commands_create_nothing() {
    let bench = Bench::new().run_by_root();

    for words in [
        &["version"][..],
        &["help"],
        &["target", "list"],
        &["vpn", "show"],
        &["timeout", "show"],
        &["token", "show"],
    ] {
        assert_eq!(bench.run(words).code, 0, "{words:?}");
    }
    assert!(!bench.ctx.system_paths.config_dir.exists());
    assert!(!bench.ctx.system_paths.state_dir.exists());
}

/// Не-root при системной установке: всё, кроме статуса, — root. Подсказка
/// называет команду целиком, код 1, своё хранилище не тронуто.
#[test]
fn a_user_on_a_system_install_is_sent_to_sudo() {
    let bench = Bench::new().with_system_install();

    for words in [
        &["target", "list"][..],
        &["target", "add", "claude"],
        &["vpn", "show"],
        &["vpn", "list"],
        &["vpn", "set", "wg0"],
        &["blacklist", "add", "RU"],
        &["whitelist", "list"],
        &["timeout", "show"],
        &["timeout", "set", "5"],
        &["token", "show"],
        &["journal"],
        &["check"],
        &["run"],
        &["service", "install"],
        &["service", "uninstall"],
        &["update"],
    ] {
        let output = bench.run(words);
        assert_eq!(output.code, 1, "{words:?}");
        assert_eq!(
            output.err,
            format!(
                "охрана установлена на всю машину — sudo weto {}\n",
                words.join(" ")
            ),
            "{words:?}"
        );
    }
    // Подсказка называет команду так, как её набрать заново: значение
    // с пробелом — в кавычках, `update install` — `update`, а токен
    // не печатается никогда — подсказка уходит на экран и в логи.
    for (words, hint) in [
        (&["token", "set", "secret-1"][..], "sudo weto token set"),
        (&["update", "install"], "sudo weto update"),
        (
            &["target", "add", "/opt/My App/app"],
            "sudo weto target add '/opt/My App/app'",
        ),
    ] {
        let output = bench.run(words);
        assert_eq!(output.code, 1, "{words:?}");
        assert_eq!(
            output.err,
            format!("охрана установлена на всю машину — {hint}\n")
        );
        assert!(!output.err.contains("secret-1"));
    }
    assert!(!bench.ctx.paths.config_dir.exists());
    assert!(
        bench.processes.asked().is_empty(),
        "сигнал root-охране не шлётся"
    );
}

/// Системный юнит без каталога настроек — тоже системная установка.
#[test]
fn a_system_unit_alone_marks_a_system_install() {
    let bench = Bench::new();
    let unit = bench.ctx.identity.system_unit_dir.join("weto.service");
    std::fs::create_dir_all(unit.parent().unwrap()).unwrap();
    std::fs::write(&unit, "").unwrap();

    assert_eq!(bench.run(&["target", "list"]).code, 1);
}

/// Открыты: справка, версия, `update check` и `service status` — root им
/// не нужен.
#[test]
fn help_version_and_update_check_need_no_sudo() {
    let bench = Bench::new().with_system_install();

    assert_eq!(bench.run(&["help"]).code, 0);
    assert_eq!(bench.run(&["vpn", "help"]).code, 0);
    assert_eq!(bench.run(&["version"]).out, "weto 0.2.0\n");
    let check = bench.run(&["update", "check"]);
    assert!(
        !check.err.contains("sudo weto update check"),
        "{}",
        check.err
    );
    assert_eq!(bench.releases.requested().len(), 1, "проверка ушла в сеть");
    assert_eq!(bench.run(&["service", "status"]).code, 0);
}

fn system_status(pid: i32) -> StatusFile {
    StatusFile {
        version: status::VERSION,
        pid,
        updated_at: now() - Duration::from_secs(2),
        last_probe_at: None,
        phase: PhaseStatus {
            kind: "protected".to_string(),
            title: "На страже".to_string(),
            action: "цели работают".to_string(),
            evidence: None,
        },
        pause_deadline: None,
        reading: None,
        outgoing: None,
        vpn: VpnStatus {
            kind: "tunnel".to_string(),
            name: Some("wg0".to_string()),
            status: "carrying".to_string(),
            via: None,
        },
        targets: Vec::new(),
        pause_ceiling_seconds: 60,
        update_available: None,
    }
}

/// `status` не-root читает системный файл статуса — он `0644`.
#[test]
fn a_user_reads_the_system_status() {
    let mut bench = Bench::new().with_system_install();
    bench.ctx.processes = Box::new(FakeProcesses::alive(&[900]));
    status::write(&bench.ctx.system_paths.status_file(), &system_status(900)).unwrap();

    let output = bench.run(&["status"]);

    assert_eq!(output.code, 0, "{}", output.err);
    assert!(
        output
            .out
            .starts_with("Охрана:   На страже — цели работают\n"),
        "{}",
        output.out
    );
    assert!(output.out.contains("VPN:      туннель wg0 — несёт трафик"));
}

/// Системная охрана остановлена — поднять её может только root; сводки
/// своих, пустых, настроек нет: она была бы неправдой о машине.
#[test]
fn a_user_without_a_running_system_guard_is_sent_to_sudo() {
    let bench = Bench::new().with_system_install();

    let output = bench.run(&["status"]);

    assert_eq!(output.code, 3);
    assert_eq!(
        output.out,
        "Охрана не запущена: sudo weto service install\n"
    );
    assert_eq!(
        output.err,
        "охрана установлена на всю машину — sudo weto status\n"
    );
}
