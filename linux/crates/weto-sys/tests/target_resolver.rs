//! Разрешение цели на настоящей файловой системе.
//!
//! Раскладка в тесте — та же, что у пакета ChatGPT от OpenAI: ярлык зовёт
//! команду по имени, команда в PATH оказывается симлинком, симлинк ведёт
//! на `sh`-скрипт, скрипт `exec`-ает соседний бинарник. Именно на этой цепочке
//! цель молча переставала совпадать с процессом: `/proc/<pid>/exe` показывает
//! последнее звено, а разрешение останавливалось на третьем.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use weto_sys::target_resolver::resolve_launch_target;

/// Пакет из четырёх звеньев. Возвращает корень раскладки и путь настоящего
/// бинарника — того, что покажет `/proc/<pid>/exe`.
fn fake_package(root: &Path) -> (PathBuf, PathBuf) {
    let bin = root.join("bin");
    let lib = root.join("lib/demo");
    let applications = root.join("applications");
    for directory in [&bin, &lib, &applications] {
        fs::create_dir_all(directory).unwrap();
    }

    // Настоящий бинарник.
    let real = lib.join("DemoApp");
    fs::write(&real, "\x7fELF настоящий бинарник").unwrap();
    fs::set_permissions(&real, fs::Permissions::from_mode(0o755)).unwrap();

    // Скрипт-запускатор рядом с ним.
    let launcher = lib.join("demo-launcher");
    fs::write(
        &launcher,
        "#!/bin/sh\nexec \"$(dirname \"$(readlink -f \"$0\")\")/DemoApp\" \"$@\"\n",
    )
    .unwrap();
    fs::set_permissions(&launcher, fs::Permissions::from_mode(0o755)).unwrap();

    // Команда в PATH — симлинк на запускатор.
    std::os::unix::fs::symlink(&launcher, bin.join("demo")).unwrap();

    // Ярлык зовёт команду по имени, да ещё с подстановкой.
    fs::write(
        applications.join("demo.desktop"),
        "[Desktop Entry]\nName=Demo\nExec=demo %U\nType=Application\n",
    )
    .unwrap();

    (root.to_path_buf(), real)
}

/// PATH на время проверки: `which` внутри границы смотрит именно туда.
fn with_path<T>(directory: &Path, body: impl FnOnce() -> T) -> T {
    let previous = std::env::var_os("PATH");
    std::env::set_var("PATH", directory);
    let outcome = body();
    match previous {
        Some(value) => std::env::set_var("PATH", value),
        None => std::env::remove_var("PATH"),
    }
    outcome
}

fn temp_dir(name: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!("weto-resolver-{name}"));
    let _ = fs::remove_dir_all(&path);
    fs::create_dir_all(&path).unwrap();
    path
}

/// Оба входа ведут к одному бинарнику: ярлык из кнопки «Выбрать…» и голое имя
/// команды, введённое руками.
///
/// Проверки объединены намеренно: `PATH` — переменная процесса, одна на все
/// потоки, и в двух параллельных тестах они затирали бы её друг у друга.
#[test]
fn both_a_desktop_entry_and_a_bare_command_reach_the_real_binary() {
    let root = temp_dir("chain");
    let (root, real) = fake_package(&root);
    let entry = root.join("applications/demo.desktop");

    let (from_entry, from_command) = with_path(&root.join("bin"), || {
        (
            resolve_launch_target(&entry.to_string_lossy()),
            resolve_launch_target("demo"),
        )
    });

    assert_eq!(from_entry, real.to_string_lossy(), "через ярлык");
    assert_eq!(from_command, real.to_string_lossy(), "через имя команды");
    let _ = fs::remove_dir_all(&root);
}

/// Обычный бинарник проходит цепочку насквозь и не меняется: лишний шаг здесь
/// означал бы цель, совпадающую не с тем процессом.
#[test]
fn an_ordinary_binary_is_left_alone() {
    let root = temp_dir("plain");
    let binary = root.join("tool");
    fs::write(&binary, "\x7fELF").unwrap();
    fs::set_permissions(&binary, fs::Permissions::from_mode(0o755)).unwrap();

    let resolved = resolve_launch_target(&binary.to_string_lossy());

    assert_eq!(
        resolved,
        fs::canonicalize(&binary).unwrap().to_string_lossy()
    );
    let _ = fs::remove_dir_all(&root);
}

/// Цель, которой на машине нет, — не ошибка: её просто ещё не установили,
/// и запись должна сохраниться как есть.
#[test]
fn a_missing_target_is_kept_verbatim() {
    assert_eq!(
        resolve_launch_target("/opt/такого/нет/never-installed"),
        "/opt/такого/нет/never-installed"
    );
}
