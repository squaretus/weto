//! Кто поднимет терминал стоящей цели.
//!
//! Порт чистой половины macOS `TerminalLocator`: там решение «который из предков
//! и есть терминал» отделено от активации через `NSRunningApplication`, здесь —
//! от вызова `org.freedesktop.Application.Activate` по шине. Ядро получает готовые
//! данные и не спрашивает ни `/proc`, ни `/usr/share/applications`, ни D-Bus.
//!
//! Фактов о предке два, и они отвечают на разные вопросы:
//!
//! * ярлык `.desktop` (`desktop_id`, `is_terminal_emulator`) говорит, **кто это**:
//!   категорию `TerminalEmulator` объявляют и gnome-console, и konsole, и xterm;
//! * имя на шине (`bus_names`) говорит, **можно ли его поднять**: сюда приходят
//!   только те имена, за которыми граница уже увидела интерфейс
//!   `org.freedesktop.Application`.
//!
//! Ни одного из двух по отдельности не хватает. У gnome-terminal ярлык
//! `org.gnome.Terminal.desktop` объявляет `Exec=gnome-terminal`, а шелл сидит
//! под `/usr/libexec/gnome-terminal-server` — по исполняемому файлу такой предок
//! не находится в индексе вовсе, зато владеет именем `org.gnome.Terminal`.
//! Обратный случай — xterm: ярлык есть и категория верная, а на шину он
//! не выходит, и поднимать его нечем.

use crate::process::{ProcessSnapshot, ProcessTree};

/// Предок стоящей цели вместе со всем, что о нём удалось узнать.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TerminalCandidate {
    pub pid: i32,
    /// Имя исполняемого файла без пути — им кандидат и называется в интерфейсе.
    pub program: String,
    /// Идентификатор ярлыка (`org.gnome.Console.desktop`), если предок нашёлся
    /// в индексе `.desktop`.
    pub desktop_id: Option<String>,
    /// Ярлык объявляет категорию `TerminalEmulator`.
    pub is_terminal_emulator: bool,
    /// Имена на шине, которыми владеет этот процесс и за которыми граница
    /// подтвердила интерфейс `org.freedesktop.Application`. Пусто — процесс
    /// поднять нечем.
    pub bus_names: Vec<String>,
}

/// Кого поднимать и чем.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalHost {
    pub pid: i32,
    pub program: String,
    pub desktop_id: Option<String>,
    /// Имя на шине. `None` — терминал опознан, но поднять его нечем: кнопки
    /// не будет, подсказка про `fg` останется.
    pub bus_name: Option<String>,
    /// Путь объекта, на котором лежит `org.freedesktop.Application`.
    pub object_path: Option<String>,
}

impl TerminalHost {
    /// Поднять можно только того, у кого есть и имя, и путь.
    pub fn can_activate(&self) -> bool {
        self.bus_name.is_some() && self.object_path.is_some()
    }
}

/// Предки процесса от ближнего к дальнему, из тех, что есть в снимке.
///
/// Ушедший предок из обхода выпадает: `ProcessTree::ancestors` знает про него
/// от ребёнка (`ppid`), но данных о нём нет — ни пути, ни родителя, — и считать
/// такой pid терминалом было бы гаданием.
pub fn ancestry(pid: i32, processes: &[ProcessSnapshot]) -> Vec<ProcessSnapshot> {
    let tree = ProcessTree::new(processes);
    tree.ancestors(pid)
        .into_iter()
        .filter_map(|ancestor| processes.iter().find(|process| process.pid == ancestor))
        .cloned()
        .collect()
}

/// Который из предков и есть терминал.
///
/// Кандидаты приходят от ближнего к дальнему, и порядок этот — часть правила:
/// выше терминала стоят `systemd --user` и `init`, а `systemd --user` тоже
/// владеет именем на шине. Ближний побеждает всегда, а из ближних — объявивший
/// себя терминалом:
///
/// 1. ближайший терминал по ярлыку, которого есть чем поднять, — обычный случай
///    (gnome-console, tilix, konsole);
/// 2. иначе ближайший процесс с именем на шине — так находится
///    `gnome-terminal-server`, которого в индексе ярлыков нет;
/// 3. иначе ближайший терминал по ярлыку без имени — xterm, alacritty, kitty:
///    кто это, мы знаем, а поднять нечем;
/// 4. иначе никого.
///
/// Самый верхний, как на macOS, здесь не годится: там признаком был путь внутри
/// `.app`, и выше бандла приложения ничего не было, а тут выше терминала всегда
/// стоит сессия пользователя.
pub fn choose(candidates: &[TerminalCandidate]) -> Option<TerminalHost> {
    let terminal_with_name = candidates
        .iter()
        .find(|candidate| candidate.is_terminal_emulator && !candidate.bus_names.is_empty());
    let any_with_name = candidates
        .iter()
        .find(|candidate| !candidate.bus_names.is_empty());
    let terminal_without_name = candidates
        .iter()
        .find(|candidate| candidate.is_terminal_emulator);

    let chosen = terminal_with_name
        .or(any_with_name)
        .or(terminal_without_name)?;

    let bus_name = preferred_bus_name(chosen);
    let object_path = bus_name.as_deref().and_then(object_path_for);

    Some(TerminalHost {
        pid: chosen.pid,
        program: chosen.program.clone(),
        desktop_id: chosen.desktop_id.clone(),
        bus_name,
        object_path,
    })
}

/// Имя из ярлыка, если процесс им владеет, иначе первое по алфавиту.
///
/// Выбор не случайный: процесс может держать несколько имён, и имя, совпавшее
/// с ярлыком, — то самое, которым приложение зовётся в системе. Алфавит нужен
/// лишь ради повторяемости: без него порядок задавал бы ответ шины.
fn preferred_bus_name(candidate: &TerminalCandidate) -> Option<String> {
    let from_desktop = candidate
        .desktop_id
        .as_deref()
        .and_then(bus_name_from_desktop_id);
    if let Some(name) = from_desktop {
        if candidate.bus_names.contains(&name) {
            return Some(name);
        }
    }
    let mut names = candidate.bus_names.clone();
    names.sort();
    names.into_iter().next()
}

/// Имя на шине из идентификатора ярлыка: `org.gnome.Console.desktop` →
/// `org.gnome.Console`. Требования к имени берутся у D-Bus, и годятся под них
/// далеко не все ярлыки: `kitty.desktop` и `mate-terminal.desktop` именем быть
/// не могут вовсе — в них нет ни одной точки.
pub fn bus_name_from_desktop_id(desktop_id: &str) -> Option<String> {
    let name = desktop_id.strip_suffix(".desktop")?;
    is_valid_bus_name(name).then(|| name.to_string())
}

/// Имя годится, если в нём хотя бы две части, каждая непуста, состоит
/// из `[A-Za-z0-9_-]` и не начинается с цифры.
pub fn is_valid_bus_name(name: &str) -> bool {
    if name.is_empty() || name.len() > 255 {
        return false;
    }
    let parts: Vec<&str> = name.split('.').collect();
    if parts.len() < 2 {
        return false;
    }
    parts.iter().all(|part| {
        !part.is_empty()
            && !part.starts_with(|c: char| c.is_ascii_digit())
            && part
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
    })
}

/// Путь объекта, на котором приложение держит `org.freedesktop.Application`:
/// точки становятся косыми, всё, что в пути запрещено, — подчёркиванием.
///
/// Хвост `-<число>` у последней части отбрасывается: приложения KDE выходят
/// на шину как `org.kde.konsole-1234` (одно имя на запуск), а интерфейс
/// приложения лежит по пути своего идентификатора — `/org/kde/konsole`.
/// Ошибка тут ничего не ломает: граница всё равно спрашивает у объекта
/// интроспекцию, и не нашедшийся интерфейс означает «поднять нечем».
pub fn object_path_for(bus_name: &str) -> Option<String> {
    if !is_valid_bus_name(bus_name) {
        return None;
    }
    let mut parts: Vec<String> = bus_name.split('.').map(str::to_string).collect();
    if let Some(last) = parts.last_mut() {
        if let Some((head, tail)) = last.rsplit_once('-') {
            if !head.is_empty() && !tail.is_empty() && tail.chars().all(|c| c.is_ascii_digit()) {
                *last = head.to_string();
            }
        }
    }

    let escaped: Vec<String> = parts
        .iter()
        .map(|part| {
            part.chars()
                .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
                .collect::<String>()
        })
        .collect();

    Some(format!("/{}", escaped.join("/")))
}

/// Имя исполняемого файла без пути. Им кандидат зовётся в индексе ярлыков
/// (`Exec=kgx`) и в интерфейсе.
pub fn program_name(executable_path: &str) -> &str {
    executable_path
        .rsplit('/')
        .next()
        .unwrap_or(executable_path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn process(pid: i32, parent: i32, path: &str) -> ProcessSnapshot {
        ProcessSnapshot {
            pid,
            parent_pid: parent,
            executable_path: path.to_string(),
            ..ProcessSnapshot::default()
        }
    }

    /// Обычное дерево: цель под шеллом, шелл под эмулятором.
    #[test]
    fn the_emulator_two_levels_up_is_found() {
        let processes = vec![
            process(1, 0, "/sbin/init"),
            process(500, 1, "/usr/bin/kgx"),
            process(600, 500, "/usr/bin/zsh"),
            process(700, 600, "/usr/bin/nano"),
        ];

        let walk = ancestry(700, &processes);
        assert_eq!(
            walk.iter().map(|p| p.pid).collect::<Vec<_>>(),
            vec![600, 500, 1],
            "предки идут от ближнего к дальнему"
        );
    }

    /// Целью может быть сам шелл — тогда терминал стоит на один шаг выше.
    #[test]
    fn the_shell_itself_as_a_target_still_finds_its_terminal() {
        let processes = vec![
            process(1, 0, "/sbin/init"),
            process(500, 1, "/usr/bin/kgx"),
            process(600, 500, "/usr/bin/zsh"),
        ];

        let walk = ancestry(600, &processes);
        assert_eq!(walk.first().map(|p| p.pid), Some(500));
    }

    /// Предок, которого в снимке уже нет, обходом не подхватывается.
    #[test]
    fn an_ancestor_that_exited_is_not_a_candidate() {
        let processes = vec![process(700, 600, "/usr/bin/nano")];

        assert!(
            ancestry(700, &processes).is_empty(),
            "о процессе 600 в снимке нет ничего, и считать его терминалом нельзя"
        );
    }

    /// Демон без терминала: предков нет вовсе.
    #[test]
    fn a_process_without_ancestors_has_no_terminal() {
        let processes = vec![process(700, 0, "/usr/bin/nano")];

        assert!(ancestry(700, &processes).is_empty());
        assert_eq!(choose(&[]), None);
    }

    fn candidate(pid: i32, program: &str) -> TerminalCandidate {
        TerminalCandidate {
            pid,
            program: program.to_string(),
            ..TerminalCandidate::default()
        }
    }

    /// Ближайший терминал по ярлыку, которого есть чем поднять.
    #[test]
    fn the_nearest_declared_terminal_with_a_name_wins() {
        let candidates = vec![
            TerminalCandidate {
                desktop_id: Some("org.gnome.Console.desktop".to_string()),
                is_terminal_emulator: true,
                bus_names: vec!["org.gnome.Console".to_string()],
                ..candidate(500, "kgx")
            },
            TerminalCandidate {
                bus_names: vec!["org.freedesktop.systemd1".to_string()],
                ..candidate(400, "systemd")
            },
        ];

        let host = choose(&candidates).expect("терминал");
        assert_eq!(host.pid, 500);
        assert_eq!(host.bus_name.as_deref(), Some("org.gnome.Console"));
        assert_eq!(host.object_path.as_deref(), Some("/org/gnome/Console"));
        assert!(host.can_activate());
    }

    /// `gnome-terminal-server` в индексе ярлыков не находится — ярлык объявляет
    /// `Exec=gnome-terminal`, — но владеет именем, и поднимается именно он.
    /// Сессия пользователя стоит выше и проигрывает по расстоянию.
    #[test]
    fn a_process_without_a_desktop_entry_is_raised_by_its_bus_name() {
        let candidates = vec![
            TerminalCandidate {
                bus_names: vec!["org.gnome.Terminal".to_string()],
                ..candidate(500, "gnome-terminal-server")
            },
            TerminalCandidate {
                bus_names: vec!["org.freedesktop.systemd1".to_string()],
                ..candidate(400, "systemd")
            },
        ];

        let host = choose(&candidates).expect("терминал");
        assert_eq!(host.pid, 500);
        assert_eq!(host.bus_name.as_deref(), Some("org.gnome.Terminal"));
    }

    /// Терминал опознан, а поднять нечем: xterm на шину не выходит. Ответ
    /// всё равно есть — интерфейс покажет подсказку без кнопки.
    #[test]
    fn a_terminal_without_a_bus_name_is_named_but_not_raisable() {
        let candidates = vec![TerminalCandidate {
            desktop_id: Some("debian-xterm.desktop".to_string()),
            is_terminal_emulator: true,
            ..candidate(500, "xterm")
        }];

        let host = choose(&candidates).expect("терминал");
        assert_eq!(host.program, "xterm");
        assert_eq!(host.bus_name, None);
        assert!(!host.can_activate());
    }

    /// Ни ярлыка, ни имени — ответа нет: поднимать `systemd` вместо терминала
    /// хуже, чем не показать кнопку.
    #[test]
    fn nothing_known_means_no_host() {
        let candidates = vec![candidate(500, "zsh"), candidate(400, "login")];
        assert_eq!(choose(&candidates), None);
    }

    /// Из нескольких имён выбирается совпавшее с ярлыком.
    #[test]
    fn the_name_matching_the_desktop_entry_is_preferred() {
        let candidates = vec![TerminalCandidate {
            desktop_id: Some("com.gexperts.Tilix.desktop".to_string()),
            is_terminal_emulator: true,
            bus_names: vec!["com.a.Helper".to_string(), "com.gexperts.Tilix".to_string()],
            ..candidate(500, "tilix")
        }];

        let host = choose(&candidates).expect("терминал");
        assert_eq!(host.bus_name.as_deref(), Some("com.gexperts.Tilix"));
    }

    #[test]
    fn desktop_ids_become_bus_names_only_when_they_can() {
        assert_eq!(
            bus_name_from_desktop_id("org.gnome.Console.desktop").as_deref(),
            Some("org.gnome.Console")
        );
        assert_eq!(
            bus_name_from_desktop_id("kitty.desktop"),
            None,
            "одна часть"
        );
        assert_eq!(
            bus_name_from_desktop_id("mate-terminal.desktop"),
            None,
            "дефис именем не спасает: точки всё равно нет"
        );
        assert_eq!(
            bus_name_from_desktop_id("org.gnome.Console"),
            None,
            "не ярлык"
        );
        assert_eq!(
            bus_name_from_desktop_id("org.1.Thing.desktop"),
            None,
            "часть с цифры"
        );
    }

    #[test]
    fn object_paths_follow_the_name() {
        assert_eq!(
            object_path_for("org.gnome.Terminal").as_deref(),
            Some("/org/gnome/Terminal")
        );
        assert_eq!(
            object_path_for("org.kde.konsole-1234").as_deref(),
            Some("/org/kde/konsole"),
            "хвост запуска KDE в путь не едет"
        );
        assert_eq!(
            object_path_for("com.my-app.Thing").as_deref(),
            Some("/com/my_app/Thing"),
            "дефис в пути запрещён"
        );
        assert_eq!(object_path_for("konsole"), None);
    }

    #[test]
    fn program_names_drop_the_path() {
        assert_eq!(
            program_name("/usr/libexec/gnome-terminal-server"),
            "gnome-terminal-server"
        );
        assert_eq!(program_name("kgx"), "kgx");
    }
}
