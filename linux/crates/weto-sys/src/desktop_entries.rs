//! Индекс ярлыков `.desktop`: по имени программы — её приложение.
//!
//! Ровно те каталоги и в том порядке, в каком их читает сам рабочий стол:
//! `$XDG_DATA_HOME/applications` (по умолчанию `~/.local/share/applications`),
//! затем `$XDG_DATA_DIRS` (по умолчанию `/usr/local/share:/usr/share`).
//! Первый нашедшийся побеждает — так пользовательский ярлык перекрывает
//! системный.
//!
//! Индексу задаётся один вопрос: кто такой этот предок стоящей цели. Ответ
//! нужен из-за категории `TerminalEmulator` — её объявляют все эмуляторы,
//! и по ней терминал отличается от прочих предков, которых у процесса
//! хватает. Поднять приложение индекс не помогает: за это отвечает шина.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DesktopEntry {
    /// Идентификатор ярлыка: имя файла относительно каталога `applications`,
    /// где разделитель каталогов заменён дефисом (`org.gnome.Console.desktop`).
    pub desktop_id: String,
    /// Ярлык объявляет категорию `TerminalEmulator`.
    pub is_terminal_emulator: bool,
    /// Ярлык скрыт из меню (`NoDisplay=true`) — такими бывают настройки
    /// приложения, и приложением они не являются.
    pub no_display: bool,
    /// У `Exec` нет аргументов: `Exec=kgx` против `Exec=kgx --preferences`.
    /// Голый запуск и есть само приложение.
    pub bare_exec: bool,
}

#[derive(Debug, Clone, Default)]
pub struct DesktopIndex {
    by_program: HashMap<String, DesktopEntry>,
}

/// Окружение, из которого берутся каталоги. Отдельным типом ради теста:
/// переменные процесса в тестах общие на все потоки, и подменять их
/// параллельным тестам нельзя.
#[derive(Debug, Clone, Default)]
pub struct XdgEnvironment {
    pub home: Option<String>,
    pub data_home: Option<String>,
    pub data_dirs: Option<String>,
}

impl XdgEnvironment {
    pub fn from_env() -> XdgEnvironment {
        XdgEnvironment {
            home: std::env::var("HOME").ok(),
            data_home: std::env::var("XDG_DATA_HOME").ok(),
            data_dirs: std::env::var("XDG_DATA_DIRS").ok(),
        }
    }
}

/// Каталоги с ярлыками в порядке убывания приоритета.
pub fn search_dirs(environment: &XdgEnvironment) -> Vec<PathBuf> {
    let mut dirs = Vec::new();

    let data_home = environment
        .data_home
        .as_deref()
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            environment
                .home
                .as_deref()
                .filter(|value| !value.is_empty())
                .map(|home| Path::new(home).join(".local/share"))
        });
    if let Some(home) = data_home {
        dirs.push(home.join("applications"));
    }

    let data_dirs = environment
        .data_dirs
        .as_deref()
        .filter(|value| !value.is_empty())
        .unwrap_or("/usr/local/share:/usr/share");
    for dir in data_dirs.split(':').filter(|value| !value.is_empty()) {
        dirs.push(Path::new(dir).join("applications"));
    }

    dirs
}

impl DesktopIndex {
    pub fn load() -> DesktopIndex {
        DesktopIndex::from_dirs(&search_dirs(&XdgEnvironment::from_env()))
    }

    pub fn from_dirs(dirs: &[PathBuf]) -> DesktopIndex {
        let mut index = DesktopIndex::default();
        for dir in dirs {
            index.absorb(dir, dir);
        }
        index
    }

    pub fn find(&self, program: &str) -> Option<&DesktopEntry> {
        self.by_program.get(program)
    }

    pub fn len(&self) -> usize {
        self.by_program.len()
    }

    pub fn is_empty(&self) -> bool {
        self.by_program.is_empty()
    }

    /// Обход одного каталога. Порядок файлов у файловой системы произвольный,
    /// поэтому имена сортируются: иначе один и тот же каталог давал бы разный
    /// индекс от запуска к запуску.
    fn absorb(&mut self, root: &Path, dir: &Path) {
        let Ok(entries) = fs::read_dir(dir) else {
            return;
        };
        let mut paths: Vec<PathBuf> = entries.flatten().map(|entry| entry.path()).collect();
        paths.sort();

        for path in paths {
            if path.is_dir() {
                self.absorb(root, &path);
                continue;
            }
            if path.extension().and_then(|value| value.to_str()) != Some("desktop") {
                continue;
            }
            let Ok(text) = fs::read_to_string(&path) else {
                continue;
            };
            let Some(id) = desktop_id(root, &path) else {
                continue;
            };
            let Some(parsed) = parse(&text, id) else {
                continue;
            };
            for program in parsed.programs {
                self.remember(program, parsed.entry.clone());
            }
        }
    }

    /// Кто из двух ярлыков описывает программу.
    ///
    /// Побеждает найденный раньше — таков порядок каталогов, — но только
    /// на равных: у gnome-terminal два ярлыка с `TryExec=gnome-terminal`,
    /// и `…Preferences.desktop` с `NoDisplay=true` и аргументом в `Exec`
    /// приложением не является.
    fn remember(&mut self, program: String, entry: DesktopEntry) {
        match self.by_program.get(&program) {
            Some(existing) if rank(existing) >= rank(&entry) => {}
            _ => {
                self.by_program.insert(program, entry);
            }
        }
    }
}

fn rank(entry: &DesktopEntry) -> u8 {
    u8::from(!entry.no_display) * 2 + u8::from(entry.bare_exec)
}

/// Идентификатор ярлыка: путь относительно корня каталога, где разделитель
/// заменён дефисом (`kde4-konsole.desktop`), — так велит спецификация меню.
fn desktop_id(root: &Path, path: &Path) -> Option<String> {
    let relative = path.strip_prefix(root).ok()?;
    Some(
        relative
            .components()
            .map(|part| part.as_os_str().to_string_lossy().into_owned())
            .collect::<Vec<_>>()
            .join("-"),
    )
}

struct Parsed {
    entry: DesktopEntry,
    programs: Vec<String>,
}

/// Разбор ярлыка. Читается только секция `[Desktop Entry]`: `[Desktop Action …]`
/// описывает пункт контекстного меню («Открыть новое окно»), и его `Exec`
/// приложением не называет никого.
fn parse(text: &str, desktop_id: String) -> Option<Parsed> {
    let mut in_entry = false;
    let mut exec: Option<String> = None;
    let mut try_exec: Option<String> = None;
    let mut categories = String::new();
    let mut no_display = false;
    let mut kind = String::new();

    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_entry = line == "[Desktop Entry]";
            continue;
        }
        if !in_entry {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        match key.trim() {
            "Exec" => exec = Some(value.trim().to_string()),
            "TryExec" => try_exec = Some(value.trim().to_string()),
            "Categories" => categories = value.trim().to_string(),
            "NoDisplay" => no_display = value.trim() == "true",
            "Type" => kind = value.trim().to_string(),
            _ => {}
        }
    }

    if !kind.is_empty() && kind != "Application" {
        return None;
    }

    let mut programs = Vec::new();
    let command = exec.as_deref().unwrap_or_default();
    let first = command.split_whitespace().next().unwrap_or_default();
    let bare_exec = !command.is_empty() && command.split_whitespace().count() == 1;

    for candidate in [first, try_exec.as_deref().unwrap_or_default()] {
        let program = program_of(candidate);
        if !program.is_empty() && !programs.iter().any(|known| known == program) {
            programs.push(program.to_string());
        }
    }
    if programs.is_empty() {
        return None;
    }

    Some(Parsed {
        entry: DesktopEntry {
            desktop_id,
            is_terminal_emulator: categories
                .split(';')
                .any(|category| category.trim() == "TerminalEmulator"),
            no_display,
            bare_exec,
        },
        programs,
    })
}

/// Имя программы из слова команды: кавычки снимаются, путь отбрасывается.
fn program_of(word: &str) -> &str {
    let word = word.trim_matches(['"', '\'']);
    word.rsplit('/').next().unwrap_or(word)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn user_applications_come_before_system_ones() {
        let environment = XdgEnvironment {
            home: Some("/home/u".to_string()),
            data_home: None,
            data_dirs: None,
        };
        assert_eq!(
            search_dirs(&environment),
            vec![
                PathBuf::from("/home/u/.local/share/applications"),
                PathBuf::from("/usr/local/share/applications"),
                PathBuf::from("/usr/share/applications"),
            ]
        );
    }

    #[test]
    fn the_environment_overrides_both_halves() {
        let environment = XdgEnvironment {
            home: Some("/home/u".to_string()),
            data_home: Some("/data".to_string()),
            data_dirs: Some("/a:/b".to_string()),
        };
        assert_eq!(
            search_dirs(&environment),
            vec![
                PathBuf::from("/data/applications"),
                PathBuf::from("/a/applications"),
                PathBuf::from("/b/applications"),
            ]
        );
    }

    /// Пустая переменная — это не «нет каталогов», а «как по умолчанию»:
    /// так её понимает спецификация XDG.
    #[test]
    fn an_empty_variable_falls_back_to_the_default() {
        let environment = XdgEnvironment {
            home: Some("/home/u".to_string()),
            data_home: Some(String::new()),
            data_dirs: Some(String::new()),
        };
        assert_eq!(
            search_dirs(&environment),
            vec![
                PathBuf::from("/home/u/.local/share/applications"),
                PathBuf::from("/usr/local/share/applications"),
                PathBuf::from("/usr/share/applications"),
            ]
        );
    }

    #[test]
    fn the_action_section_names_nobody() {
        let parsed = parse(
            "[Desktop Entry]\nExec=kgx\nCategories=System;TerminalEmulator;\n\
             [Desktop Action new-window]\nExec=kgx --window\n",
            "org.gnome.Console.desktop".to_string(),
        )
        .expect("ярлык");
        assert_eq!(parsed.programs, vec!["kgx".to_string()]);
        assert!(parsed.entry.is_terminal_emulator);
        assert!(parsed.entry.bare_exec);
    }
}
