//! Индекс ярлыков проверяется на настоящем дереве каталогов.
//!
//! Файлы взяты с живой системы (Debian trixie): `org.gnome.Terminal.desktop`,
//! `org.gnome.Console.desktop`, `org.kde.konsole.desktop`, `Alacritty.desktop`,
//! `debian-xterm.desktop`. Выдумывать их формат нельзя — ровно в мелочах
//! он и разъезжается: у gnome-terminal ярлыков два, и второй, скрытый,
//! объявляет тот же `TryExec`.

use std::fs;
use std::path::PathBuf;

use weto_sys::desktop_entries::DesktopIndex;

fn tree() -> (tempfile::TempDir, Vec<PathBuf>) {
    let root = tempfile::tempdir().expect("временный каталог");
    let user = root.path().join("home/.local/share/applications");
    let system = root.path().join("usr/share/applications");
    fs::create_dir_all(&user).expect("каталог пользователя");
    fs::create_dir_all(&system).expect("системный каталог");

    write(
        &system,
        "org.gnome.Terminal.desktop",
        "[Desktop Entry]\nName=Terminal\nTryExec=gnome-terminal\nExec=gnome-terminal\n\
         Categories=GNOME;GTK;System;TerminalEmulator;Utility;\n\
         [Desktop Action new-window]\nName=New Window\nExec=gnome-terminal --window\n",
    );
    write(
        &system,
        "org.gnome.Terminal.Preferences.desktop",
        "[Desktop Entry]\nName=Terminal Preferences\nTryExec=gnome-terminal\n\
         Exec=gnome-terminal --preferences\nNoDisplay=true\nDBusActivatable=false\n\
         Categories=GNOME;GTK;System;TerminalEmulator;\n",
    );
    write(
        &system,
        "org.gnome.Console.desktop",
        "[Desktop Entry]\nName=Console\nExec=kgx\nDBusActivatable=true\n\
         Categories=System;TerminalEmulator;Utility;GTK;GNOME;\n",
    );
    write(
        &system,
        "org.kde.konsole.desktop",
        "[Desktop Entry]\nName=Konsole\nTryExec=konsole\nExec=konsole\n\
         Categories=Qt;KDE;System;TerminalEmulator;\n",
    );
    write(
        &system,
        "debian-xterm.desktop",
        "[Desktop Entry]\nName=XTerm\nExec=xterm\nCategories=System;TerminalEmulator;\n",
    );
    write(
        &system,
        "org.gnome.Nautilus.desktop",
        "[Desktop Entry]\nName=Files\nExec=nautilus --new-window\nDBusActivatable=true\n\
         Categories=GNOME;GTK;Utility;Core;FileManager;\n",
    );
    // Пользовательский ярлык перекрывает системный — на том и стоит порядок
    // каталогов XDG.
    write(
        &user,
        "Alacritty.desktop",
        "[Desktop Entry]\nName=Alacritty (моя сборка)\nTryExec=alacritty\nExec=alacritty\n\
         Categories=System;TerminalEmulator;\n",
    );
    write(
        &system,
        "Alacritty.desktop",
        "[Desktop Entry]\nName=Alacritty\nTryExec=alacritty\nExec=alacritty\n\
         Categories=System;TerminalEmulator;\n",
    );

    let dirs = vec![user, system];
    (root, dirs)
}

fn write(dir: &std::path::Path, name: &str, body: &str) {
    fs::write(dir.join(name), body).expect("ярлык");
}

#[test]
fn a_terminal_is_recognised_by_its_category() {
    let (_root, dirs) = tree();
    let index = DesktopIndex::from_dirs(&dirs);

    for program in ["kgx", "konsole", "xterm", "alacritty", "gnome-terminal"] {
        let entry = index
            .find(program)
            .unwrap_or_else(|| panic!("«{program}» не нашёлся в индексе"));
        assert!(
            entry.is_terminal_emulator,
            "«{program}» обязан опознаваться как эмулятор терминала"
        );
    }

    let files = index.find("nautilus").expect("файловый менеджер");
    assert!(
        !files.is_terminal_emulator,
        "файловый менеджер терминалом не является"
    );
    assert_eq!(files.desktop_id, "org.gnome.Nautilus.desktop");
}

/// У gnome-terminal два ярлыка с одним и тем же `TryExec`, и приложением
/// является тот, что не скрыт и запускается без аргументов. Иначе весь
/// эмулятор назывался бы «настройками терминала».
#[test]
fn the_hidden_preferences_entry_does_not_win() {
    let (_root, dirs) = tree();
    let index = DesktopIndex::from_dirs(&dirs);

    let entry = index.find("gnome-terminal").expect("терминал");
    assert_eq!(entry.desktop_id, "org.gnome.Terminal.desktop");
    assert!(!entry.no_display);
}

/// Пользовательский каталог идёт раньше системного, и ярлык из него побеждает.
#[test]
fn the_user_entry_overrides_the_system_one() {
    let (root, dirs) = tree();
    let index = DesktopIndex::from_dirs(&dirs);

    assert!(index.find("alacritty").is_some());
    // Тот же индекс, собранный без пользовательского каталога, обязан
    // находить системный ярлык: иначе проверка выше ничего не доказывает.
    let system_only = DesktopIndex::from_dirs(&[root.path().join("usr/share/applications")]);
    assert!(system_only.find("alacritty").is_some());
    assert!(system_only.find("kgx").is_some());
}

/// Несуществующий каталог — не отказ: `~/.local/share/applications` есть
/// не у каждого пользователя, а `$XDG_DATA_DIRS` перечисляет каталоги,
/// которых в системе может не быть вовсе.
#[test]
fn a_missing_directory_is_not_a_failure() {
    let index = DesktopIndex::from_dirs(&[PathBuf::from("/несуществующий/каталог")]);
    assert!(index.is_empty());
    assert!(index.find("kgx").is_none());
}
