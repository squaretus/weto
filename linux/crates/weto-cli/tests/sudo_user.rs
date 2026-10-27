//! Голое имя цели под `sudo` ищется по `PATH` того, кто вызвал `sudo`:
//! найденное у root — само имя; не найденное у root — путь у пользователя
//! без разворота симлинков и третья строка; шелл молчит — каталоги домашнего;
//! нигде — прежняя подсказка; не под root или без `SUDO_USER` — как раньше.

mod support;

use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::{Path, PathBuf};

use support::Bench;

/// Имя, которого заведомо нет в `PATH` root.
const TOOL: &str = "weto-test-tool";

/// Дом пользователя: версионный файл и симлинк на него в `~/.local/bin` —
/// так ставятся claude и codex.
fn user_home(bench: &Bench) -> (PathBuf, PathBuf) {
    let home = bench.home.path().join("home/u");
    let versioned = home.join(".local/share/tool/versions/2.1.228");
    std::fs::create_dir_all(versioned.parent().unwrap()).unwrap();
    std::fs::write(&versioned, "#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(&versioned, std::fs::Permissions::from_mode(0o755)).unwrap();
    let link = home.join(".local/bin").join(TOOL);
    std::fs::create_dir_all(link.parent().unwrap()).unwrap();
    symlink(&versioned, &link).unwrap();
    (home, link)
}

fn sudo_bench() -> Bench {
    let mut bench = Bench::new().run_by_root();
    bench.ctx.sudo_user = Some("u".to_string());
    bench
}

fn shell_path(bench: &Bench, path: &Path) {
    *bench.user_paths.path.lock().unwrap() = Some(format!("/usr/bin:{}", path.display()));
}

/// Найдено у root — запись прежняя: само имя, пользователя не спрашивают.
#[test]
fn a_name_root_finds_stays_a_name() {
    let bench = sudo_bench();

    let output = bench.run(&["target", "add", "sh"]);

    assert_eq!(output.code, 0, "{}", output.err);
    assert_eq!(bench.settings().targets[0].entry, "sh");
    assert!(!output.out.contains("PATH пользователя"));
    assert!(bench.user_paths.asked().is_empty());
}

/// Не найдено у root, найдено в `PATH` логин-шелла пользователя — пишется
/// путь симлинка, а не версионный файл; имя — введённое; третья строка.
#[test]
fn a_name_found_in_the_users_path_is_stored_as_its_link() {
    let bench = sudo_bench();
    let (_, link) = user_home(&bench);
    shell_path(&bench, link.parent().unwrap());

    let output = bench.run(&["target", "add", TOOL]);

    assert_eq!(output.code, 0, "{}", output.err);
    let target = &bench.settings().targets[0];
    let path = link.to_string_lossy().into_owned();
    assert_eq!(target.entry, path);
    assert_eq!(target.launch_paths, std::slice::from_ref(&path));
    assert_eq!(target.display_name, TOOL);
    let lines: Vec<&str> = output.out.lines().collect();
    assert_eq!(lines[0], format!("Цель добавлена: {TOOL}"));
    assert!(lines[1].contains("versions/2.1.228"), "{}", lines[1]);
    assert_eq!(lines[2], format!("  найдено в PATH пользователя u: {path}"));
    assert_eq!(bench.user_paths.asked(), ["u"]);

    let again = bench.run(&["target", "add", TOOL]);
    assert_eq!(again.code, 1);
    assert!(again.err.contains("такая цель уже есть в списке"));

    assert_eq!(bench.run(&["target", "remove", TOOL]).code, 0, "по имени");
    assert!(bench.settings().targets.is_empty());
}

/// Шелл не ответил — каталоги домашнего.
#[test]
fn a_silent_shell_falls_back_to_the_home_directories() {
    let bench = sudo_bench();
    let (home, link) = user_home(&bench);
    *bench.user_paths.home.lock().unwrap() = Some(home);

    let output = bench.run(&["target", "add", TOOL]);

    assert_eq!(output.code, 0, "{}", output.err);
    assert_eq!(bench.settings().targets[0].entry, link.to_string_lossy());
    assert!(output.out.contains("найдено в PATH пользователя u: "));
}

/// Нигде нет — как раньше: имя записано, подсказка про полный путь.
#[test]
fn a_name_found_nowhere_keeps_the_old_hint() {
    let bench = sudo_bench();
    *bench.user_paths.home.lock().unwrap() = Some(bench.home.path().join("home/u"));

    let output = bench.run(&["target", "add", TOOL]);

    assert_eq!(output.code, 0, "{}", output.err);
    assert_eq!(bench.settings().targets[0].entry, TOOL);
    assert_eq!(
        output.out,
        format!("Цель добавлена: {TOOL}\n  не найдено по имени — укажите полный путь к файлу\n")
    );
}

/// Не под root или без `SUDO_USER` — пользователя не спрашивают вовсе.
#[test]
fn without_sudo_nothing_changes() {
    let mut user = Bench::new();
    user.ctx.sudo_user = Some("u".to_string());
    let (_, link) = user_home(&user);
    shell_path(&user, link.parent().unwrap());
    assert_eq!(user.run(&["target", "add", TOOL]).code, 0);
    assert_eq!(user.settings().targets[0].entry, TOOL);

    let root = Bench::new().run_by_root();
    let (_, link) = user_home(&root);
    shell_path(&root, link.parent().unwrap());
    assert_eq!(root.run(&["target", "add", TOOL]).code, 0);
    assert_eq!(root.settings().targets[0].entry, TOOL);

    assert!(user.user_paths.asked().is_empty());
    assert!(root.user_paths.asked().is_empty());
}

/// `vpn set` — та же ветка приложения: путь у пользователя и третья строка
/// под «VPN-приложение: …».
#[test]
fn vpn_set_finds_the_app_in_the_users_path() {
    let bench = sudo_bench();
    let (_, link) = user_home(&bench);
    shell_path(&bench, link.parent().unwrap());

    let output = bench.run(&["vpn", "set", TOOL]);

    assert_eq!(output.code, 0, "{}", output.err);
    let app = bench.settings().vpn_app.expect("приложение выбрано");
    assert_eq!(app.entry, link.to_string_lossy());
    assert_eq!(app.display_name, TOOL);
    let lines: Vec<&str> = output.out.lines().collect();
    assert!(
        lines[0].starts_with(&format!("VPN-приложение: {TOOL} (")),
        "{}",
        output.out
    );
    assert_eq!(
        lines[1],
        format!("  найдено в PATH пользователя u: {}", link.display())
    );
}

/// Интерфейс с таким именем решает раньше: пользователя не спрашивают.
#[test]
fn an_interface_is_not_looked_up_in_the_users_path() {
    let bench = sudo_bench();
    bench.interfaces.set(&["lo", TOOL]);

    assert_eq!(bench.run(&["vpn", "set", TOOL]).code, 0);
    assert_eq!(bench.settings().vpn_tunnel.as_deref(), Some(TOOL));
    assert!(bench.user_paths.asked().is_empty());
}
