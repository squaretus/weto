//! Разрешение цели на Windows: какой файл запустится по записи настроек
//! и как узнавать его процессы.
//!
//! Формы записи:
//! - полный путь к программе (`C:\Users\u\.local\bin\claude.exe`) — разворачивается
//!   канонизацией: ссылки WinGet (`%LOCALAPPDATA%\Microsoft\WinGet\Links`) —
//!   симлинки, а ядро называет процесс по конечному файлу;
//! - голое имя (`claude`) — ищется по `PATH` с расширениями из `PATHEXT`,
//!   как его нашёл бы `cmd`;
//! - ярлык меню «Пуск» (`…\Programs\Happ.lnk`) — аналог `.desktop` на Linux:
//!   программа ищется по ярлыку заново при каждом разрешении (`shortcut`);
//! - npm-шим (`claude.cmd`) — `cmd` запускает `node.exe <скрипт>`, и процесс цели —
//!   node со скриптом в командной строке. Шим разбирается до скрипта, вид — скрипт,
//!   как скрипт с шебангом на Linux.
//!
//! Чужой `.bat`/`.cmd`, не npm-шим, — запись вида «скрипт» со своим путём:
//! его процесс — `cmd /c "путь"` (ядро разбирает эту строку,
//! `process::command_processor_script`). Скрипт, набранный в уже открытом
//! `cmd`, исполняет сам этот шелл, и отдельного процесса у него нет.
//!
//! Логика без вызовов Windows API и тестируется где угодно; `PATH` и `PATHEXT`
//! приходят параметрами, чтобы тесты не делили переменные процесса.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};

use weto_config::settings::Target;
use weto_core::path_text::{file_name, is_absolute, program_stem};
use weto_core::process::TargetKind;
use weto_sys::target_resolver::{LocatedTarget, TargetResolving};

use crate::shortcut::{self, is_shortcut};

/// `PATHEXT` по умолчанию — когда переменной нет.
pub const DEFAULT_PATHEXT: &str = ".COM;.EXE;.BAT;.CMD";

/// Настоящее разрешение: `PATH` и `PATHEXT` процесса, читаются на каждый вопрос —
/// охрана спрашивает раз в две секунды, а пользователь мог поставить инструмент.
#[derive(Debug, Clone, Copy, Default)]
pub struct WindowsTargetResolver;

impl TargetResolving for WindowsTargetResolver {
    fn locate(&self, entry: &str) -> Option<LocatedTarget> {
        let pathext = std::env::var("PATHEXT").ok();
        locate_in(
            entry,
            std::env::var_os("PATH").as_deref(),
            pathext.as_deref(),
        )
    }

    fn kind_of(&self, path: &str) -> Option<TargetKind> {
        kind_of_file(Path::new(path))
    }
}

/// Запись настроек для цели или VPN-приложения — одна дорога для окна
/// и команд моста. Путь — тот, что запустится сейчас; пути запуска — сама
/// запись и, для голого имени, файл в `PATH` как он там лежит (`…\npm\claude.cmd`):
/// охрана разрешает цель заново, и шим переживает обновление, а развёрнутый
/// путь скрипта или версионной программы — нет. Имя — переданное снаружи
/// (подпись ярлыка из меню «Пуск»), иначе имя файла без `.exe`.
pub fn settings_target(
    text: &str,
    display_name: Option<String>,
    search_path: Option<&OsStr>,
    pathext: Option<&str>,
) -> Target {
    let text = text.trim();
    let located = locate_in(text, search_path, pathext);
    let mut launch_paths = vec![text.to_string()];
    if file_name(text) == text {
        let found = search_path
            .and_then(|path| find_in_path(text, path, pathext.unwrap_or(DEFAULT_PATHEXT)));
        if let Some(found) = found {
            let found = found.to_string_lossy().into_owned();
            if !launch_paths.contains(&found) {
                launch_paths.push(found);
            }
        }
    }
    Target {
        entry: text.to_string(),
        display_name: display_name.unwrap_or_else(|| default_name(text)),
        kind: located
            .as_ref()
            .map_or(TargetKind::Binary, |found| found.kind),
        path: located.map_or_else(|| text.to_string(), |found| found.path),
        launch_paths,
    }
}

/// Имя цели, когда снаружи его не дали: у ярлыка — подпись ярлыка, как `Name=`
/// у `.desktop` на Linux; у программы — имя файла без `.exe`.
fn default_name(entry: &str) -> String {
    let name = program_stem(entry);
    if is_shortcut(name) {
        name[..name.len() - 4].to_string()
    } else {
        name.to_string()
    }
}

/// То же с `PATH` и `PATHEXT` процесса.
pub fn settings_target_now(text: &str, display_name: Option<String>) -> Target {
    let pathext = std::env::var("PATHEXT").ok();
    settings_target(
        text,
        display_name,
        std::env::var_os("PATH").as_deref(),
        pathext.as_deref(),
    )
}

/// Цель по записи при заданных `PATH` и `PATHEXT`. `None` — нового знания нет:
/// файла нет (обновление как раз меняет его) или вид не прочитать.
pub fn locate_in(
    entry: &str,
    search_path: Option<&OsStr>,
    pathext: Option<&str>,
) -> Option<LocatedTarget> {
    let entry = entry.trim();
    if is_shortcut(entry) {
        // Ярлык ведёт на программу, а не на другой ярлык: цепочек не разбираем.
        let target = shortcut::resolve(Path::new(entry)).filter(|target| !is_shortcut(target))?;
        return locate_in(&target, search_path, pathext);
    }
    let file = if is_absolute(entry) {
        Some(PathBuf::from(entry)).filter(|path| path.is_file())
    } else if file_name(entry) == entry && !entry.is_empty() {
        find_in_path(entry, search_path?, pathext.unwrap_or(DEFAULT_PATHEXT))
    } else {
        // Относительный путь с каталогами: от чьего рабочего каталога — неизвестно.
        None
    }?;

    if has_extension(&file, &["cmd", "bat"]) {
        let path = match std::fs::read_to_string(&file)
            .ok()
            .and_then(|text| npm_shim_script(&text, file.parent()?))
        {
            Some(script) => canonical(&script)?,
            None => canonical(&file)?,
        };
        return Some(LocatedTarget {
            path,
            kind: TargetKind::Script,
        });
    }

    let path = canonical(&file)?;
    let kind = kind_of_file(Path::new(&path))?;
    Some(LocatedTarget { path, kind })
}

/// Файл голой команды: каталоги `PATH` по порядку, в каждом — имя как есть,
/// если у него уже есть расширение из `PATHEXT`, иначе имя с каждым
/// расширением по порядку `PATHEXT`. Так ищет `cmd`.
pub fn find_in_path(command: &str, search_path: &OsStr, pathext: &str) -> Option<PathBuf> {
    let extensions: Vec<&str> = pathext
        .split(';')
        .map(str::trim)
        .filter(|extension| extension.starts_with('.'))
        .collect();
    let has_known_extension = extensions.iter().any(|extension| {
        command.len() > extension.len()
            && command[command.len() - extension.len()..].eq_ignore_ascii_case(extension)
    });
    std::env::split_paths(search_path)
        .filter(|directory| directory.is_absolute())
        .find_map(|directory| {
            if has_known_extension {
                Some(directory.join(command)).filter(|candidate| candidate.is_file())
            } else {
                extensions
                    .iter()
                    // В нижнем регистре: Windows регистра не различает, а npm
                    // пишет шимы именно так (`claude.cmd`).
                    .map(|extension| {
                        directory.join(format!("{command}{}", extension.to_ascii_lowercase()))
                    })
                    .find(|candidate| candidate.is_file())
            }
        })
}

/// Скрипт, который запускает npm-шим (`cmd-shim`): путь в кавычках от каталога
/// шима — `"%dp0%\node_modules\…\cli.js"` у нынешних шимов, `"%~dp0\…"` у старых.
/// Сам `node.exe` рядом с шимом скриптом не является. `None` — это не npm-шим.
pub fn npm_shim_script(shim: &str, shim_dir: &Path) -> Option<PathBuf> {
    let relative = ["\"%dp0%\\", "\"%~dp0\\"]
        .iter()
        .flat_map(|marker| {
            shim.match_indices(marker).filter_map(move |(at, _)| {
                let rest = &shim[at + marker.len()..];
                rest.find('"').map(|end| &rest[..end])
            })
        })
        .filter(|path| !file_name(path).eq_ignore_ascii_case("node.exe") && !path.is_empty())
        .last()?;

    let mut script = shim_dir.to_path_buf();
    for part in relative.split(['\\', '/']) {
        match part {
            "" | "." => {}
            ".." => {
                script.pop();
            }
            part => script.push(part),
        }
    }
    Some(script)
}

/// Конечный файл записи, без префикса `\\?\`, который ставит `canonicalize`
/// на Windows: в процессе путь записан без него, и сравнение не совпало бы.
pub fn canonical(path: &Path) -> Option<String> {
    let resolved = std::fs::canonicalize(path).ok()?;
    Some(without_verbatim_prefix(&resolved.to_string_lossy()))
}

/// `\\?\C:\x` → `C:\x`, `\\?\UNC\сервер\x` → `\\сервер\x`; прочее — как есть.
pub fn without_verbatim_prefix(path: &str) -> String {
    if let Some(rest) = path.strip_prefix(r"\\?\UNC\") {
        format!(r"\\{rest}")
    } else if let Some(rest) = path.strip_prefix(r"\\?\") {
        rest.to_string()
    } else {
        path.to_string()
    }
}

/// Вид по первым байтам: `MZ` — программа Windows, иначе — то, что запускается
/// интерпретатором. Файл короче сигнатуры или нечитаемый ответа не даёт:
/// так выглядит переустановка инструмента посреди записи файла.
pub fn kind_of_file(path: &Path) -> Option<TargetKind> {
    use std::io::Read;

    let mut head = [0u8; 2];
    let mut file = std::fs::File::open(path).ok()?;
    let mut filled = 0;
    while filled < head.len() {
        match file.read(&mut head[filled..]) {
            Ok(0) => return None,
            Ok(read) => filled += read,
            Err(_) => return None,
        }
    }
    Some(if &head == b"MZ" {
        TargetKind::Binary
    } else {
        TargetKind::Script
    })
}

fn has_extension(path: &Path, wanted: &[&str]) -> bool {
    path.extension()
        .and_then(OsStr::to_str)
        .is_some_and(|extension| wanted.iter().any(|w| extension.eq_ignore_ascii_case(w)))
}

#[cfg(test)]
mod tests {
    use super::*;

    const SHIM: &str = r#"@ECHO off
GOTO start
:find_dp0
SET dp0=%~dp0
EXIT /b
:start
SETLOCAL
CALL :find_dp0

IF EXIST "%dp0%\node.exe" (
  SET "_prog=%dp0%\node.exe"
) ELSE (
  SET "_prog=node"
  SET PATHEXT=%PATHEXT:;.JS;=;%
)

endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "%_prog%"  "%dp0%\node_modules\@anthropic-ai\claude-code\cli.js" %*
"#;

    fn write(path: &Path, content: &[u8]) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, content).unwrap();
    }

    #[test]
    fn an_npm_shim_names_its_script_not_node() {
        let dir = Path::new("/npm");

        assert_eq!(
            npm_shim_script(SHIM, dir),
            Some(PathBuf::from(
                "/npm/node_modules/@anthropic-ai/claude-code/cli.js"
            ))
        );
    }

    #[test]
    fn an_old_shim_with_tilde_dp0_and_parent_steps_is_understood() {
        let shim = r#"@"%~dp0\..\lib\node_modules\qwen\cli.js" %*"#;

        assert_eq!(
            npm_shim_script(shim, Path::new("/tools/bin")),
            Some(PathBuf::from("/tools/lib/node_modules/qwen/cli.js"))
        );
    }

    #[test]
    fn an_ordinary_batch_file_is_not_a_shim() {
        assert_eq!(
            npm_shim_script("@echo off\r\nstart notepad.exe\r\n", Path::new("/x")),
            None
        );
    }

    #[test]
    fn the_verbatim_prefix_is_dropped() {
        assert_eq!(
            without_verbatim_prefix(r"\\?\C:\tools\a.exe"),
            r"C:\tools\a.exe"
        );
        assert_eq!(
            without_verbatim_prefix(r"\\?\UNC\srv\share\a.exe"),
            r"\\srv\share\a.exe"
        );
        assert_eq!(without_verbatim_prefix("/usr/bin/node"), "/usr/bin/node");
    }

    #[test]
    fn a_bare_name_is_searched_with_pathext_in_order() {
        let home = tempfile::tempdir().unwrap();
        let first = home.path().join("first");
        let second = home.path().join("second");
        write(&first.join("claude.cmd"), SHIM.as_bytes());
        write(&second.join("claude.exe"), b"MZ\x90\x00");
        let path = std::env::join_paths([&first, &second]).unwrap();

        // .EXE раньше .CMD в PATHEXT, но каталог first раньше second в PATH:
        // cmd берёт первый каталог, где нашлось хоть что-то.
        assert_eq!(
            find_in_path("claude", &path, DEFAULT_PATHEXT),
            Some(first.join("claude.cmd"))
        );
        assert_eq!(
            find_in_path("claude.exe", &path, DEFAULT_PATHEXT),
            Some(second.join("claude.exe"))
        );
        assert_eq!(find_in_path("codex", &path, DEFAULT_PATHEXT), None);
    }

    #[test]
    fn an_npm_shim_target_is_located_as_its_script() {
        let home = tempfile::tempdir().unwrap();
        let bin = home.path().join("npm");
        let cli = bin.join("node_modules/@anthropic-ai/claude-code/cli.js");
        write(&bin.join("claude.cmd"), SHIM.as_bytes());
        write(&cli, b"#!/usr/bin/env node\n");
        let path = std::env::join_paths([&bin]).unwrap();

        let located = locate_in("claude", Some(&path), None).unwrap();

        assert_eq!(located.kind, TargetKind::Script);
        assert_eq!(located.path, canonical(&cli).unwrap());
    }

    #[test]
    fn a_program_is_a_binary_and_a_short_file_gives_no_answer() {
        let home = tempfile::tempdir().unwrap();
        let program = home.path().join("tool.exe");
        let empty = home.path().join("empty.exe");
        write(&program, b"MZ\x90\x00\x03");
        write(&empty, b"M");

        let located = locate_in(&program.to_string_lossy(), None, None).unwrap();

        assert_eq!(located.kind, TargetKind::Binary);
        assert_eq!(
            locate_in(&empty.to_string_lossy(), None, None),
            None,
            "недописанный файл — не ответ"
        );
    }

    #[test]
    fn a_settings_target_remembers_the_shim_found_in_path() {
        let home = tempfile::tempdir().unwrap();
        let bin = home.path().join("npm");
        let cli = bin.join("node_modules/@anthropic-ai/claude-code/cli.js");
        write(&bin.join("claude.cmd"), SHIM.as_bytes());
        write(&cli, b"#!/usr/bin/env node\n");
        let path = std::env::join_paths([&bin]).unwrap();

        let target = settings_target(" claude ", None, Some(&path), None);

        assert_eq!(target.entry, "claude");
        assert_eq!(target.display_name, "claude");
        assert_eq!(target.kind, TargetKind::Script);
        assert_eq!(target.path, canonical(&cli).unwrap());
        assert_eq!(
            target.launch_paths,
            vec![
                "claude".to_string(),
                bin.join("claude.cmd").to_string_lossy().into_owned()
            ]
        );
    }

    #[test]
    fn a_missing_program_is_kept_as_typed_and_named_without_exe() {
        let target = settings_target(r"C:\nowhere\Tool.EXE", None, None, None);

        assert_eq!(target.display_name, "Tool");
        assert_eq!(target.path, r"C:\nowhere\Tool.EXE");
        assert_eq!(target.kind, TargetKind::Binary);
        assert_eq!(
            settings_target("tool", Some("Мой инструмент".into()), None, None).display_name,
            "Мой инструмент"
        );
    }

    #[test]
    fn a_relative_path_with_directories_is_not_resolved() {
        let path = std::env::join_paths([std::env::temp_dir()]).unwrap();

        assert_eq!(locate_in(r"tools\claude.exe", Some(&path), None), None);
    }
}
