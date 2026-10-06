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

use weto_core::process::TargetKind;

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
    walk(entry).resolution
}

/// Конец цепочки и то, как до него дошли.
struct Walk {
    resolution: Resolution,
    /// Последнее звено передал интерпретатор (`Exec=node /opt/app/cli.js`):
    /// файл запустится не сам, и в `exe` процесса его не будет никогда.
    interpreted: bool,
}

fn walk(entry: &str) -> Walk {
    let mut current = entry.to_string();
    let mut interpreted = false;

    for _ in 0..MAX_HOPS {
        let path = canonical(&current).unwrap_or_else(|| current.clone());

        match next_hop(&path) {
            Hop::Next(next) => {
                current = next;
                interpreted = false;
            }
            Hop::Interpreted(script) => {
                current = script;
                interpreted = true;
            }
            Hop::Foreign(launcher) => {
                return Walk {
                    resolution: Resolution::NeedsPath { launcher },
                    interpreted: false,
                }
            }
            Hop::Stop => {
                return Walk {
                    resolution: Resolution::Resolved(path),
                    interpreted,
                }
            }
        }
    }
    Walk {
        resolution: Resolution::Resolved(current),
        interpreted,
    }
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
    locate_target_with_kind(entry).map(|found| found.path)
}

/// Файл цели и то, как её узнавать среди процессов.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocatedTarget {
    pub path: String,
    pub kind: TargetKind,
}

/// Где цель лежит сейчас и какого она вида — порт макосного
/// `TargetResolver.rule(forEntry:at:)`.
///
/// Вид решает сам файл, а не то, как его назвали: скрипт ядро запускает
/// интерпретатором, `/proc/<pid>/exe` называет `node`, и цель вида «бинарник»
/// не совпала бы ни с одним процессом — `qwen` из npm оставался без охраны
/// молча. Файл, который ярлык передаёт интерпретатору, — скрипт, даже
/// без шебанга.
pub fn locate_target_with_kind(entry: &str) -> Option<LocatedTarget> {
    let walk = walk(entry);
    match walk.resolution {
        Resolution::Resolved(path) if Path::new(&path).is_file() => {
            let kind = if walk.interpreted {
                TargetKind::Script
            } else {
                kind_of_file(&path)
            };
            Some(LocatedTarget { path, kind })
        }
        _ => None,
    }
}

/// Вид цели для записи в настройки. Цели, которой на диске нет, вид узнать
/// не из чего — она записывается бинарником, а охрана выведет вид заново,
/// когда файл появится.
pub fn target_kind_for(entry: &str) -> TargetKind {
    locate_target_with_kind(entry).map_or(TargetKind::Binary, |found| found.kind)
}

/// Вид по первым байтам файла — целиком не читается: бинарник инструмента
/// весит сотни мегабайт, а охрана спрашивает раз в две секунды.
///
/// Шебанг — скрипт, как на macOS. Но на Linux мерило шире: ядро исполняет
/// напрямую только ELF, всё прочее — шебанг-скрипт или формат binfmt_misc —
/// запускает интерпретатором, и `exe` у такого процесса — интерпретатор.
/// Поэтому не-ELF с содержимым узнаётся по argv: по пути он не совпал бы
/// никогда. Нечитаемый или пустой файл остаётся бинарником — скрипт
/// интерпретатору обязан быть читаем.
fn kind_of_file(path: &str) -> TargetKind {
    use std::io::Read;

    let mut head = [0u8; 4];
    let mut filled = 0;
    if let Ok(mut file) = std::fs::File::open(path) {
        while filled < head.len() {
            match file.read(&mut head[filled..]) {
                Ok(0) | Err(_) => break,
                Ok(read) => filled += read,
            }
        }
    }
    let head = &head[..filled];
    if head.starts_with(b"#!") {
        TargetKind::Script
    } else if head.is_empty() || head == b"\x7fELF" {
        TargetKind::Binary
    } else {
        TargetKind::Script
    }
}

/// Граница разрешения цели для охраны. Порт макосного `TargetResolving`.
///
/// Охране мало пути, запомненного при добавлении: у инструментов из версионного
/// каталога (`~/.local/share/claude/versions/2.1.228`) обновление меняет
/// развёрнутый путь целиком, и правило, разрешённое однажды, молча переставало
/// совпадать с новым процессом. Поэтому охрана спрашивает заново — а тесту
/// нужно подменить ответ, не трогая диск.
pub trait TargetResolving: Send + Sync {
    /// Файл, который запустится по записи сейчас, или `None`, если ответа нет:
    /// файла на диске нет (его как раз подменяет обновление) или ярлык ведёт
    /// к чужому запускатору. `None` — не «цели больше нет», а «нового знания нет».
    fn locate(&self, entry: &str) -> Option<LocatedTarget>;
}

/// Настоящее разрешение — та же цепочка, что у описания цели в настройках.
/// Голые имена ищутся по `PATH` самого процесса: на Linux его даёт сессия
/// рабочего стола, а не launchd, как на macOS.
#[derive(Debug, Clone, Copy, Default)]
pub struct LaunchTargetResolver;

impl TargetResolving for LaunchTargetResolver {
    fn locate(&self, entry: &str) -> Option<LocatedTarget> {
        locate_target_with_kind(entry)
    }
}

/// Пути запуска, которые стоит запомнить вместе с целью при добавлении:
/// сама запись и, для голого имени, файл в `PATH`, на котором она нашлась
/// (`~/.local/bin/claude`), — без разворота симлинков.
///
/// Нужен тот, что до разворота: симлинк в `PATH` переживает обновление,
/// а развёрнутый путь — нет. Если позже охрана не найдёт голое имя (её `PATH`
/// не тот, что у терминала, где цель добавляли), разрешение начнётся с него.
pub fn launch_paths_for(entry: &str) -> Vec<String> {
    launch_paths_in(entry, std::env::var_os("PATH").as_deref())
}

/// То же с явно заданным `PATH`: переменная процесса одна на все потоки,
/// и тесты, меняющие её параллельно, затирали бы её друг у друга.
pub fn launch_paths_in(entry: &str, search_path: Option<&std::ffi::OsStr>) -> Vec<String> {
    let mut paths = vec![entry.to_string()];
    if let Some(found) = search_path.and_then(|value| path_entry(entry, value)) {
        let found = found.to_string_lossy().into_owned();
        if !paths.contains(&found) {
            paths.push(found);
        }
    }
    paths
}

/// Файл голой команды в `PATH` как он там лежит — без разворота симлинков.
fn path_entry(command: &str, search_path: &std::ffi::OsStr) -> Option<PathBuf> {
    if command.is_empty() || command.contains('/') {
        return None;
    }
    std::env::split_paths(search_path)
        .filter(|directory| directory.is_absolute())
        .map(|directory| directory.join(command))
        .find(|candidate| candidate.is_file())
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
    /// Файл, который ярлык передаёт интерпретатору: процессом станет
    /// интерпретатор, а файл — его аргументом.
    Interpreted(String),
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
            Some(weto_core::launcher::DesktopCommand::Script(script)) => Hop::Interpreted(script),
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
