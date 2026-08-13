//! Что на самом деле запустится, когда пользователь выбрал «приложение».
//!
//! Порт границы `TargetResolving` с macOS. Там она разворачивает симлинки
//! и достаёт идентификатор бандла; здесь цепочка длиннее, потому что бандлов
//! нет: ярлык `.desktop` → команда → запись в PATH → симлинк → скрипт-запускатор
//! → соседний бинарник.
//!
//! Пройти её обязано приложение, а не пользователь. Иначе цель добавлена,
//! в списке выглядит живой, а при падении VPN не завершается — то самое тихое
//! несрабатывание, ради которого продукт и существует.
//!
//! Разбор текста живёт в ядре (`weto_core::launcher`), здесь — только диск.

use std::path::{Path, PathBuf};

/// Сколько звеньев цепочки проходим. Больше не нужно ни одному известному
/// случаю, а ограничение спасает от кольца из симлинков.
const MAX_HOPS: usize = 4;

/// Каталоги с ярлыками приложений — местный аналог `/Applications`.
///
/// Системный идёт первым, и это не вкусовщина: в пользовательском обычно лежит
/// один-два ярлыка (в том числе наш собственный), а всё установленное —
/// в системном. Открытый не там диалог выглядит пустым, и приложение в нём
/// «нигде не находится».
pub fn applications_dirs() -> Vec<PathBuf> {
    let mut dirs = vec![PathBuf::from("/usr/share/applications")];
    if let Some(home) = std::env::var_os("HOME") {
        dirs.push(PathBuf::from(home).join(".local/share/applications"));
    }
    dirs
}

/// Путь того, что действительно запустится.
///
/// Нерасходящаяся цель возвращается как есть: команда, которой нет на машине,
/// — не ошибка, а цель, которую ещё не установили.
pub fn resolve_launch_target(entry: &str) -> String {
    let mut current = entry.to_string();

    for _ in 0..MAX_HOPS {
        let path = canonical(&current).unwrap_or_else(|| current.clone());

        match next_hop(&path) {
            Some(next) => current = next,
            None => return path,
        }
    }
    current
}

fn canonical(text: &str) -> Option<String> {
    std::fs::canonicalize(text)
        .ok()
        .or_else(|| which(text))
        .map(|path| path.to_string_lossy().into_owned())
}

/// Следующее звено цепочки, если оно есть.
fn next_hop(path: &str) -> Option<String> {
    let file = Path::new(path);

    if path.ends_with(".desktop") {
        let text = std::fs::read_to_string(file).ok()?;
        return weto_core::launcher::command_from_desktop_entry(&text);
    }

    // Скрипт читается как текст; на бинарнике чтение просто не сложится.
    let text = std::fs::read_to_string(file).ok()?;
    let neighbour = weto_core::launcher::sibling_binary_from_launcher(&text)?;
    let candidate = file.parent()?.join(neighbour);

    candidate
        .is_file()
        .then(|| candidate.to_string_lossy().into_owned())
}

/// Команда из PATH: `canonicalize` умеет только пути, а в ярлыках сплошь
/// голые имена вроде `chatgpt`.
fn which(command: &str) -> Option<PathBuf> {
    if command.contains('/') {
        return None;
    }
    std::env::split_paths(&std::env::var_os("PATH")?)
        .map(|directory| directory.join(command))
        .find(|candidate| candidate.is_file())
        .and_then(|candidate| std::fs::canonicalize(candidate).ok())
}
