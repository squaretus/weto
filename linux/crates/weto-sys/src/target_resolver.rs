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
//! Кончается цепочка не всегда путём: у Steam и flatpak программу заводит
//! сам запускатор, и какой файл окажется процессом, из ярлыка не следует.
//! Догадка там стоила бы всего продукта — целью стал бы `/usr/bin/steam`,
//! и падение VPN закрывало бы Steam со всеми играми. Поэтому ответ честный,
//! `NeedsPath`, а путь спрашивают у пользователя.
//!
//! Разбор текста живёт в ядре (`weto_core::launcher`), здесь — только диск.

use std::path::{Path, PathBuf};

/// Сколько звеньев цепочки проходим. Больше не нужно ни одному известному
/// случаю, а ограничение спасает от кольца из симлинков.
const MAX_HOPS: usize = 4;

/// Крупнее этого скрипт-запускатор не бывает: он из нескольких строк.
/// Предел не даёт читать целиком бинарник — у инструментов он весит сотни
/// мегабайт, а описание цели в настройках спрашивает границу каждую секунду.
const LAUNCHER_SIZE_LIMIT: u64 = 256 * 1024;

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

/// Чем кончилась цепочка.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Resolution {
    /// Путь того, что действительно запустится.
    Resolved(String),
    /// Цепочка упёрлась в чужой запускатор: программу заводит он, и какой
    /// это будет файл, из ярлыка не следует. Спросить остаётся у пользователя.
    NeedsPath { launcher: String },
}

/// Чем кончилась цепочка — с честным «не знаю» вместо догадки.
///
/// Нерасходящаяся цель возвращается как есть: команда, которой нет на машине,
/// — не ошибка, а цель, которую ещё не установили.
pub fn resolve_launch_entry(entry: &str) -> Resolution {
    let mut current = entry.to_string();

    for _ in 0..MAX_HOPS {
        let path = canonical(&current).unwrap_or_else(|| current.clone());

        match next_hop(&path) {
            Hop::Next(next) => current = next,
            Hop::Foreign(launcher) => return Resolution::NeedsPath { launcher },
            Hop::Stop => return Resolution::Resolved(path),
        }
    }
    Resolution::Resolved(current)
}

/// Строковый фасад для тех, кому нужен один только путь.
///
/// Чужой запускатор здесь выглядит так же, как цель, которой на машине нет:
/// запись остаётся как введена. Выдумывать за пользователя путь нечем,
/// а спрашивать — работа интерфейса, не границы.
pub fn resolve_launch_target(entry: &str) -> String {
    match resolve_launch_entry(entry) {
        Resolution::Resolved(path) => path,
        Resolution::NeedsPath { .. } => entry.to_string(),
    }
}

/// Где цель лежит сейчас — или `None`, если на диске за ней ничего нет.
///
/// Для описания цели в настройках, а не для охраны: охране ненайденная цель
/// не ошибка, а экрану нужен ответ «не найдено», и `resolve_launch_target`
/// его не даёт — запись, за которой ничего нет, он возвращает как есть.
/// Спрашивается при каждой перерисовке: обновление инструмента
/// из версионного каталога меняет развёрнутый путь целиком. Чужой
/// запускатор — тоже «не найдено»: файла программы ярлык не называет.
pub fn locate_target(entry: &str) -> Option<String> {
    match resolve_launch_entry(entry) {
        Resolution::Resolved(path) if Path::new(&path).is_file() => Some(path),
        _ => None,
    }
}

/// Имя приложения из ярлыка — то, которое пользователь видел в диалоге выбора.
///
/// Последний сегмент пути именем не является: у инструментов из версионного
/// каталога там стоит версия, и цель подписывалась «2.1.241». Читает файл
/// эта сторона границы, разбирает текст — ядро.
pub fn display_name_for(entry: &str) -> Option<String> {
    if !entry.ends_with(".desktop") {
        return None;
    }
    let text = std::fs::read_to_string(entry).ok()?;
    weto_core::launcher::name_from_desktop_entry(&text, ui_locale().as_deref())
}

/// Иконка приложения из ярлыка — для пилюли цели. Как и имя: файл читает
/// граница, текст разбирает ядро. У цели, заданной не ярлыком, иконки нет.
pub fn icon_for(entry: &str) -> Option<String> {
    if !entry.ends_with(".desktop") {
        return None;
    }
    let text = std::fs::read_to_string(entry).ok()?;
    weto_core::launcher::icon_from_desktop_entry(&text)
}

/// Язык интерфейса — первые две буквы из `LANG` или `LC_MESSAGES`.
///
/// Ровно то, чем локализованные ключи ярлыка и подписаны (`Name[ru]`):
/// полная форма `ru_RU.UTF-8` не совпала бы ни с одним из них.
fn ui_locale() -> Option<String> {
    let value = std::env::var("LC_MESSAGES")
        .or_else(|_| std::env::var("LANG"))
        .ok()?;
    let short: String = value.chars().take(2).collect();
    (short.len() == 2 && short.chars().all(|c| c.is_ascii_alphabetic())).then_some(short)
}

fn canonical(text: &str) -> Option<String> {
    std::fs::canonicalize(text)
        .ok()
        .or_else(|| which(text))
        .map(|path| path.to_string_lossy().into_owned())
}

/// Куда ведёт очередное звено.
enum Hop {
    /// Следующее звено цепочки.
    Next(String),
    /// Чужой запускатор: дальше цепочки нет и быть не может.
    Foreign(String),
    /// Дальше идти некуда — это и есть цель.
    Stop,
}

/// Следующее звено цепочки, если оно есть.
fn next_hop(path: &str) -> Hop {
    let file = Path::new(path);

    if path.ends_with(".desktop") {
        let Ok(text) = std::fs::read_to_string(file) else {
            return Hop::Stop;
        };
        return match weto_core::launcher::command_from_desktop_entry(&text) {
            Some(weto_core::launcher::DesktopCommand::Command(command)) => Hop::Next(command),
            Some(weto_core::launcher::DesktopCommand::Indirect { launcher }) => {
                Hop::Foreign(launcher)
            }
            None => Hop::Stop,
        };
    }

    // Скрипт читается как текст; на бинарнике чтение просто не сложится.
    // Но сперва размер: чтобы «не сложиться», `read_to_string` прочёл бы
    // бинарник целиком.
    let small = std::fs::metadata(file).is_ok_and(|meta| meta.len() <= LAUNCHER_SIZE_LIMIT);
    let neighbour = small
        .then(|| std::fs::read_to_string(file).ok())
        .flatten()
        .and_then(|text| weto_core::launcher::sibling_binary_from_launcher(&text));
    let Some(neighbour) = neighbour else {
        return Hop::Stop;
    };
    let Some(candidate) = file.parent().map(|parent| parent.join(neighbour)) else {
        return Hop::Stop;
    };

    if candidate.is_file() {
        Hop::Next(candidate.to_string_lossy().into_owned())
    } else {
        Hop::Stop
    }
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
