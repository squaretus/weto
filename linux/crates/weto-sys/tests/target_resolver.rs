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

use weto_core::process::TargetKind;
use weto_sys::target_resolver::{
    icon_for, launch_paths_in, locate_target, locate_target_with_kind, resolve_launch_entry,
    resolve_launch_target, target_kind_for, LaunchTargetResolver, LocatedTarget, Resolution,
    TargetResolving,
};

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
///
/// Переменная одна на процесс, а тесты идут параллельно: без замка два теста
/// с подменой затирали бы `PATH` друг у друга.
fn with_path<T>(directory: &Path, body: impl FnOnce() -> T) -> T {
    static PATH_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let _guard = PATH_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
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

/// Ярлык игры Steam: до настоящей программы из него не добраться ничем —
/// процесс заводит сам Steam, и какой это будет файл, в тексте не написано.
/// Догадка стоила бы дорого: целью стал бы `/usr/bin/steam`, и падение VPN
/// закрывало бы Steam целиком со всеми играми. Граница обязана ответить
/// «нужен путь», а не путём.
#[test]
fn a_steam_entry_asks_for_the_program_path() {
    let root = temp_dir("steam");
    let entry = root.join("game.desktop");
    fs::write(
        &entry,
        "[Desktop Entry]\nName=Factorio\nExec=steam steam://rungameid/367520\nType=Application\n",
    )
    .unwrap();

    let resolution = resolve_launch_entry(&entry.to_string_lossy());

    assert_eq!(
        resolution,
        Resolution::NeedsPath {
            launcher: "steam".to_string()
        }
    );
    // Строковый фасад в этом случае оставляет запись как есть — как и всякую
    // другую нерешаемую цель: выдумывать за пользователя путь тут нечем.
    assert_eq!(
        resolve_launch_target(&entry.to_string_lossy()),
        entry.to_string_lossy()
    );
    let _ = fs::remove_dir_all(&root);
}

/// Ярлык VPN-клиента из flatpak. Спросить путь здесь дороже, чем у цели:
/// невыбранное VPN-приложение не значит ничего, а выбранное и не запущенное —
/// доказательство, то есть завершение всех целей разом. Запись, принятая
/// молча, не совпала бы ни с одним процессом, и падение целей случилось бы
/// на ровном месте. Дорога к этому ответу одна на все поля ввода: и цель,
/// и VPN-приложение спрашивают одну и ту же границу.
#[test]
fn a_flatpak_vpn_client_asks_for_the_program_path() {
    let root = temp_dir("flatpak");
    let entry = root.join("vpn.desktop");
    fs::write(
        &entry,
        "[Desktop Entry]\nName=VPN Client\nExec=/usr/bin/flatpak run --branch=stable com.example.Vpn %U\nType=Application\n",
    )
    .unwrap();

    assert_eq!(
        resolve_launch_entry(&entry.to_string_lossy()),
        Resolution::NeedsPath {
            launcher: "flatpak".to_string()
        }
    );
    let _ = fs::remove_dir_all(&root);
}

/// Ярлык, у которого команда спрятана за оболочкой так, что вынуть её нечем,
/// тоже просит путь — вместо того чтобы объявить целью `/bin/bash` и увести
/// под охрану половину машины.
#[test]
fn an_unparsed_shell_entry_asks_for_the_program_path() {
    let root = temp_dir("shell-wrapper");
    let entry = root.join("wrapped.desktop");
    fs::write(
        &entry,
        "[Desktop Entry]\nName=Wrapped\nExec=bash --norc -c \"/opt/app/app\"\nType=Application\n",
    )
    .unwrap();

    assert_eq!(
        resolve_launch_entry(&entry.to_string_lossy()),
        Resolution::NeedsPath {
            launcher: "bash".to_string()
        }
    );
    let _ = fs::remove_dir_all(&root);
}

/// Обычный ярлык «нужен путь» не просит: программа названа прямо, и цепочка
/// доходит до файла на диске. Иначе запрос пути выскакивал бы на каждом
/// добавлении и обесценивал бы сам себя.
#[test]
fn an_ordinary_entry_resolves_without_asking() {
    let root = temp_dir("ordinary");
    let entry = root.join("shell.desktop");
    fs::write(
        &entry,
        "[Desktop Entry]\nName=Shell\nExec=/bin/sh --login\nType=Application\n",
    )
    .unwrap();

    let resolution = resolve_launch_entry(&entry.to_string_lossy());

    assert_eq!(
        resolution,
        Resolution::Resolved(
            fs::canonicalize("/bin/sh")
                .unwrap()
                .to_string_lossy()
                .into_owned()
        )
    );
    let _ = fs::remove_dir_all(&root);
}

/// Иконка пилюли читается из ярлыка, который выбрал пользователь; у команды
/// и бинарника её нет, и пилюля рисует значок терминала.
#[test]
fn the_icon_is_read_from_the_chosen_entry() {
    let root = temp_dir("icon");
    let entry = root.join("editor.desktop");
    fs::write(
        &entry,
        "[Desktop Entry]\nName=Editor\nIcon=accessories-text-editor\nExec=/bin/sh\n",
    )
    .unwrap();

    assert_eq!(
        icon_for(&entry.to_string_lossy()).as_deref(),
        Some("accessories-text-editor")
    );
    assert_eq!(icon_for("/bin/sh"), None);
    assert_eq!(
        icon_for(&root.join("missing.desktop").to_string_lossy()),
        None
    );
    let _ = fs::remove_dir_all(&root);
}

/// Настройки спрашивают границу заново при каждой перерисовке, а не помнят путь
/// с момента добавления: обновление инструмента из версионного каталога меняет
/// развёрнутый путь целиком, и описание цели показывало бы удалённую версию.
#[test]
fn a_target_is_located_where_it_points_now() {
    let root = temp_dir("versions");
    let versions = root.join("versions");
    fs::create_dir_all(&versions).unwrap();
    for version in ["2.1.228", "2.1.241"] {
        let binary = versions.join(version);
        fs::write(&binary, "\x7fELF").unwrap();
        fs::set_permissions(&binary, fs::Permissions::from_mode(0o755)).unwrap();
    }
    let link = root.join("claude");
    std::os::unix::fs::symlink(versions.join("2.1.228"), &link).unwrap();
    let entry = link.to_string_lossy().into_owned();

    let before = locate_target(&entry);
    fs::remove_file(&link).unwrap();
    std::os::unix::fs::symlink(versions.join("2.1.241"), &link).unwrap();
    let after = locate_target(&entry);

    let canonical = |version: &str| {
        fs::canonicalize(versions.join(version))
            .unwrap()
            .to_string_lossy()
            .into_owned()
    };
    assert_eq!(before, Some(canonical("2.1.228")));
    assert_eq!(after, Some(canonical("2.1.241")));
    let _ = fs::remove_dir_all(&root);
}

/// Граница путь не выдумывает: запись, за которой на диске ничего нет, —
/// «не найдено», а не сама запись, выданная за путь.
#[test]
fn a_target_that_is_not_on_disk_is_not_located() {
    assert_eq!(locate_target("/opt/такого/нет/never-installed"), None);
    assert_eq!(locate_target("weto-never-installed-command"), None);
}

/// Целиком читается только то, что может быть скриптом-запускатором.
/// Описание цели в настройках спрашивает границу каждую секунду, а бинарник
/// инструмента весит сотни мегабайт — `claude` около двухсот: чтение его
/// целиком ради проверки «не скрипт ли это» гоняло бы их по памяти
/// на каждой перерисовке. Запускатор — несколько строк, и файл крупнее
/// предела им не считается, даже если начинается как скрипт.
#[test]
fn a_file_too_large_for_a_launcher_is_not_read_as_one() {
    let root = temp_dir("large");
    let neighbour = root.join("DemoApp");
    fs::write(&neighbour, "\x7fELF").unwrap();
    let large = root.join("demo-launcher");
    let mut text =
        String::from("#!/bin/sh\nexec \"$(dirname \"$(readlink -f \"$0\")\")/DemoApp\" \"$@\"\n");
    text.push_str(&"#\n".repeat(1024 * 1024));
    fs::write(&large, text).unwrap();

    assert_eq!(
        resolve_launch_target(&large.to_string_lossy()),
        fs::canonicalize(&large).unwrap().to_string_lossy(),
    );
    let _ = fs::remove_dir_all(&root);
}

/// Голое имя запоминается вместе с файлом в `PATH`, на котором оно нашлось, —
/// симлинком, а не развёрнутым путём: симлинк переживает обновление
/// инструмента, развёрнутый путь — нет. С него охрана и начнёт, если сама
/// голого имени не найдёт.
#[test]
fn a_bare_command_is_remembered_with_its_path_entry() {
    let root = temp_dir("path-entry");
    let versions = root.join("versions");
    let bin = root.join("bin");
    fs::create_dir_all(&versions).unwrap();
    fs::create_dir_all(&bin).unwrap();
    let binary = versions.join("2.1.228");
    fs::write(&binary, "\x7fELF").unwrap();
    fs::set_permissions(&binary, fs::Permissions::from_mode(0o755)).unwrap();
    std::os::unix::fs::symlink(&binary, bin.join("claude")).unwrap();
    let search = std::env::join_paths([root.join("пусто"), bin.clone()]).unwrap();

    assert_eq!(
        launch_paths_in("claude", Some(&search)),
        vec![
            "claude".to_string(),
            bin.join("claude").to_string_lossy().into_owned()
        ],
    );
    // Путь — уже путь: искать его в `PATH` нечего.
    let entry = bin.join("claude").to_string_lossy().into_owned();
    assert_eq!(launch_paths_in(&entry, Some(&search)), vec![entry.clone()]);
    // Команды нет нигде — запоминается только запись.
    assert_eq!(
        launch_paths_in("weto-never-installed-command", Some(&search)),
        vec!["weto-never-installed-command".to_string()],
    );
    let _ = fs::remove_dir_all(&root);
}

/// Охрана спрашивает границу через `TargetResolving`: ответ обязан следовать
/// за симлинком, перевешенным обновлением, а цель, которой на диске на миг
/// нет, ответа не получает — это «нового знания нет», а не путь.
#[test]
fn the_guard_resolver_follows_a_retargeted_symlink() {
    let root = temp_dir("guard-resolver");
    let versions = root.join("versions");
    fs::create_dir_all(&versions).unwrap();
    for version in ["228", "300"] {
        let binary = versions.join(version);
        fs::write(&binary, "\x7fELF").unwrap();
        fs::set_permissions(&binary, fs::Permissions::from_mode(0o755)).unwrap();
    }
    let link = root.join("claude");
    std::os::unix::fs::symlink(versions.join("228"), &link).unwrap();
    let entry = link.to_string_lossy().into_owned();
    let resolver = LaunchTargetResolver;
    let canonical = |version: &str| {
        fs::canonicalize(versions.join(version))
            .unwrap()
            .to_string_lossy()
            .into_owned()
    };

    let binary = |version: &str| {
        Some(LocatedTarget {
            path: canonical(version),
            kind: TargetKind::Binary,
        })
    };

    assert_eq!(resolver.locate(&entry), binary("228"));
    fs::remove_file(&link).unwrap();
    assert_eq!(resolver.locate(&entry), None, "симлинка на мгновение нет");
    std::os::unix::fs::symlink(versions.join("300"), &link).unwrap();
    assert_eq!(resolver.locate(&entry), binary("300"));
    let _ = fs::remove_dir_all(&root);
}

/// `qwen` из npm: в `PATH` лежит симлинк на `cli.js`, а тот начинается
/// с `#!/usr/bin/env node`. Ядро запускает такой файл интерпретатором,
/// и `/proc/<pid>/exe` называет `/usr/bin/node`, а не `cli.js`. Цель вида
/// «бинарник» не совпадала ни с одним процессом — `qwen` оставался без охраны
/// молча. Вид решает сам файл: шебанг — скрипт, совпадение по argv.
#[test]
fn a_shebang_file_behind_a_path_symlink_is_a_script() {
    let root = temp_dir("shebang");
    let bin = root.join("bin");
    let dist = root.join("lib/node_modules/qwen/dist");
    fs::create_dir_all(&bin).unwrap();
    fs::create_dir_all(&dist).unwrap();
    let cli = dist.join("cli.js");
    fs::write(&cli, "#!/usr/bin/env node\nconsole.log('qwen')\n").unwrap();
    fs::set_permissions(&cli, fs::Permissions::from_mode(0o755)).unwrap();
    let link = bin.join("qwen");
    std::os::unix::fs::symlink(&cli, &link).unwrap();
    let expected = Some(LocatedTarget {
        path: fs::canonicalize(&cli)
            .unwrap()
            .to_string_lossy()
            .into_owned(),
        kind: TargetKind::Script,
    });

    let (by_name, kind_by_name) = with_path(&bin, || {
        (locate_target_with_kind("qwen"), target_kind_for("qwen"))
    });

    assert_eq!(by_name, expected, "голое имя из PATH");
    assert_eq!(kind_by_name, TargetKind::Script);
    assert_eq!(
        LaunchTargetResolver.locate(&link.to_string_lossy()),
        expected,
        "охрана получает вид вместе с путём"
    );
    let _ = fs::remove_dir_all(&root);
}

/// Обратная сторона: бинарник остаётся бинарником — и тогда, когда до него
/// ведёт `sh`-запускатор с соседним бинарником. Сам запускатор начинается
/// с шебанга, но целью он не является: цепочка доходит до соседа, а процессом
/// оказывается именно сосед.
#[test]
fn binaries_stay_binaries_even_behind_a_shell_launcher() {
    let root = temp_dir("binary-kind");
    let (root, real) = fake_package(&root);
    let plain = root.join("tool");
    fs::write(&plain, "\x7fELF").unwrap();
    fs::set_permissions(&plain, fs::Permissions::from_mode(0o755)).unwrap();

    assert_eq!(
        locate_target_with_kind(&plain.to_string_lossy()).map(|found| found.kind),
        Some(TargetKind::Binary)
    );
    assert_eq!(
        locate_target_with_kind(&root.join("bin/demo").to_string_lossy()),
        Some(LocatedTarget {
            path: real.to_string_lossy().into_owned(),
            kind: TargetKind::Binary,
        })
    );
    // Цели, которой на диске нет, вид не из чего узнать — она остаётся
    // бинарником, как была бы записана и раньше.
    assert_eq!(
        target_kind_for("/opt/такого/нет/never-installed"),
        TargetKind::Binary
    );
    let _ = fs::remove_dir_all(&root);
}

/// Ярлык `Exec=node /opt/app/cli.js`: процессом окажется `node`, и цель
/// `/usr/bin/node` увела бы под охрану все Node-процессы машины разом.
/// Цель — сам файл, вид — скрипт, даже без шебанга: ядро ELF-а в нём
/// не найдёт, и в `exe` он не появится никогда — только в argv.
#[test]
fn a_file_run_by_an_interpreter_from_an_entry_is_a_script() {
    let root = temp_dir("interpreted");
    let cli = root.join("cli.js");
    fs::write(&cli, "console.log('без шебанга')\n").unwrap();
    let entry = root.join("app.desktop");
    fs::write(
        &entry,
        format!(
            "[Desktop Entry]\nName=App\nExec=node {} %U\nType=Application\n",
            cli.display()
        ),
    )
    .unwrap();
    let bare = root.join("repl.desktop");
    fs::write(&bare, "[Desktop Entry]\nName=REPL\nExec=node\n").unwrap();

    assert_eq!(
        locate_target_with_kind(&entry.to_string_lossy()),
        Some(LocatedTarget {
            path: fs::canonicalize(&cli)
                .unwrap()
                .to_string_lossy()
                .into_owned(),
            kind: TargetKind::Script,
        })
    );
    // Файла скрипта ярлык не назвал — интерпретатор целью не становится,
    // путь спросят у пользователя.
    assert_eq!(
        resolve_launch_entry(&bare.to_string_lossy()),
        Resolution::NeedsPath {
            launcher: "node".to_string()
        }
    );
    // Тот же файл, указанный пользователем во втором диалоге, — тоже скрипт.
    assert_eq!(target_kind_for(&cli.to_string_lossy()), TargetKind::Script);
    let _ = fs::remove_dir_all(&root);
}
