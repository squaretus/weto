//! Пути как текст — для двух систем сразу.
//!
//! Ядро файлов не трогает, но пути сравнивает и режет: имя интерпретатора,
//! имя цели без ярлыка, абсолютность пути скрипта. Процессы на Linux называют
//! себя `/usr/bin/node`, на Windows — `C:\Program Files\nodejs\node.exe`,
//! и разбор, знающий только `/`, на Windows не узнавал бы ни одного
//! интерпретатора и ни одного абсолютного пути.
//!
//! Обе формы понимаются на обеих системах: обратная косая в имени файла
//! на Linux законна, но в путях целей и интерпретаторов не встречается.
//! Различается только регистр — его различает файловая система.

/// Последний сегмент пути: после последнего `/` или `\`, без хвостовых
/// разделителей (`/opt/tool/` → `tool`).
pub fn file_name(path: &str) -> &str {
    let path = path.trim_end_matches(['/', '\\']);
    path.rsplit(['/', '\\']).next().unwrap_or(path)
}

/// Имя программы без `.exe` (в любом регистре): `node.exe` и `node` — один
/// интерпретатор.
pub fn program_stem(path: &str) -> &str {
    let name = file_name(path);
    match name.len().checked_sub(4) {
        Some(cut) if name.is_char_boundary(cut) && name[cut..].eq_ignore_ascii_case(".exe") => {
            &name[..cut]
        }
        _ => name,
    }
}

/// Абсолютный путь: `/…` у unix, `C:\…`, `C:/…` и UNC `\\сервер\…` у Windows.
/// `C:файл` (относительно текущего каталога диска) абсолютным не считается.
pub fn is_absolute(path: &str) -> bool {
    let bytes = path.as_bytes();
    path.starts_with('/')
        || path.starts_with(r"\\")
        || (bytes.len() >= 3
            && bytes[0].is_ascii_alphabetic()
            && bytes[1] == b':'
            && (bytes[2] == b'\\' || bytes[2] == b'/'))
}

/// Один ли это файл по записи пути. На Windows регистр не различается:
/// файловая система его не различает, а путь процесса приходит в том регистре,
/// каким его открыли (`c:\tools\Claude.EXE`). На Linux различается.
///
/// На Windows сравнивается и запись пути, а не только буквы: npm-шим `claude.cmd`
/// передаёт node путь скрипта как `%~dp0\node_modules\…`, а `%~dp0` уже кончается
/// разделителем, и node получает `npm\\node_modules\…`; шим PowerShell пишет
/// `npm/node_modules/…`. Правило же хранит путь в обычной записи, и цель,
/// поставленная npm, с ним не совпадала. Поэтому `/` и `\` равны, повторы
/// разделителей и сегменты `.` не значат ничего, `..` снимает предыдущий сегмент.
pub fn same_path(left: &str, right: &str) -> bool {
    if cfg!(windows) {
        same_windows_path(left, right)
    } else {
        left == right
    }
}

fn same_windows_path(left: &str, right: &str) -> bool {
    if left.eq_ignore_ascii_case(right) {
        return true;
    }
    // Почти все сравнения — с чужими процессами: несовпавшее имя файла отсеивает
    // их без разбора пути целиком.
    if !same_letters(file_name(left), file_name(right)) {
        return false;
    }
    let (left_unc, left) = windows_segments(left);
    let (right_unc, right) = windows_segments(right);
    left_unc == right_unc
        && left.len() == right.len()
        && left.iter().zip(&right).all(|(a, b)| same_letters(a, b))
}

/// Голое имя цели называет программу, а не файл: на Windows так её знают
/// Диспетчер задач и `taskkill /IM`. `Claude` и `claude.exe` совпадают с любым
/// `…\claude.exe`. Нужно для приложений из Microsoft Store: ярлыка в меню «Пуск»
/// у них нет, каталог `WindowsApps` закрыт и меняет имя с каждой версией,
/// и вписать пользователь может только имя.
///
/// На Linux — никогда: у нативного claude последний сегмент пути — номер версии,
/// а голое имя ищется по `PATH`.
pub fn names_program(name: &str, executable_path: &str) -> bool {
    cfg!(windows)
        && !name.is_empty()
        && file_name(name) == name
        && same_letters(program_stem(name), program_stem(executable_path))
}

/// Та же программа другой версии: пути различаются только номером версии внутри
/// каталогов, а имя файла то же.
///
/// Каталог многих программ называется по версии, и стабильного пути над ним нет:
/// приложение Microsoft Store живёт в `WindowsApps\Claude_6.28899.6.0_x64__…\app`,
/// обновляемое Squirrel — в `app-1.0.9`, node под nvm — в `v20.11.0`. Обновление
/// кладёт программу в соседний каталог и удаляет прежний, и цель, записанная
/// прежним путём, молча переставала совпадать с чем-либо. Разрешать её заново
/// нечем: файла больше нет, а `WindowsApps` обычному пользователю даже не
/// перечислить.
///
/// Версия — первая в сегменте серия чисел через точку, не меньше двух
/// (`6.28899.6.0`, `1.0.10`, `2024.1`); всё до и после неё обязано совпасть:
/// у Store это имя пакета, архитектура и издатель. Одиночное число версией
/// не считается (`Python311`, ревизия snap `123`), имя файла сравнивается
/// точно: `python3.12` рядом с `python3.11` — другая программа.
pub fn same_program_across_versions(left: &str, right: &str) -> bool {
    if !is_absolute(left) || !is_absolute(right) {
        return false;
    }
    if cfg!(windows) {
        windows_across_versions(left, right)
    } else {
        unix_across_versions(left, right)
    }
}

fn windows_across_versions(left: &str, right: &str) -> bool {
    let (left_unc, left) = windows_segments(left);
    let (right_unc, right) = windows_segments(right);
    left_unc == right_unc && segments_across_versions(&left, &right, same_letters)
}

fn unix_across_versions(left: &str, right: &str) -> bool {
    let left: Vec<&str> = left.split('/').filter(|s| !s.is_empty()).collect();
    let right: Vec<&str> = right.split('/').filter(|s| !s.is_empty()).collect();
    segments_across_versions(&left, &right, |a, b| a == b)
}

fn segments_across_versions(left: &[&str], right: &[&str], same: fn(&str, &str) -> bool) -> bool {
    let (Some(left_file), Some(right_file)) = (left.last(), right.last()) else {
        return false;
    };
    // Почти все сравнения — с чужими процессами: несовпавшее имя файла отсеивает
    // их без разбора каталогов.
    if left.len() != right.len() || !same(left_file, right_file) {
        return false;
    }
    left.iter().zip(right).all(|(a, b)| {
        same(a, b)
            || match (version_split(a), version_split(b)) {
                (Some((a_head, a_tail)), Some((b_head, b_tail))) => {
                    same(a_head, b_head) && same(a_tail, b_tail)
                }
                _ => false,
            }
    })
}

/// Сегмент вокруг первой серии чисел через точку (не меньше двух чисел):
/// то, что до неё, и то, что после. `None` — версии в сегменте нет.
fn version_split(segment: &str) -> Option<(&str, &str)> {
    let bytes = segment.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if !bytes[index].is_ascii_digit() {
            index += 1;
            continue;
        }
        let start = index;
        let mut numbers = 0;
        loop {
            while index < bytes.len() && bytes[index].is_ascii_digit() {
                index += 1;
            }
            numbers += 1;
            let continues = bytes.get(index) == Some(&b'.')
                && bytes.get(index + 1).is_some_and(u8::is_ascii_digit);
            if !continues {
                break;
            }
            index += 1;
        }
        // Цифры и точка — ASCII: обе границы приходятся на границы символов.
        if numbers >= 2 {
            return Some((&segment[..start], &segment[index..]));
        }
    }
    None
}

/// Без учёта регистра и за пределами ASCII: `C:\Проекты` и `c:\проекты` — один каталог.
fn same_letters(left: &str, right: &str) -> bool {
    left.chars()
        .flat_map(char::to_lowercase)
        .eq(right.chars().flat_map(char::to_lowercase))
}

/// Сегменты пути без пустых и `.`, с разобранными `..`; признак UNC (`\\сервер\…`)
/// отдельно — он, в отличие от повтора разделителей, значим. `..` в корне не уводит
/// выше корня, как и у самой системы.
fn windows_segments(path: &str) -> (bool, Vec<&str>) {
    let unc = path.starts_with(r"\\") || path.starts_with("//");
    let mut segments: Vec<&str> = Vec::new();
    for segment in path.split(['/', '\\']) {
        match segment {
            "" | "." => {}
            ".." => {
                // Диск (`C:`) остаётся: выше корня подняться нельзя.
                if segments.len() > 1 || segments.first().is_some_and(|first| !first.ends_with(':'))
                {
                    segments.pop();
                }
            }
            _ => segments.push(segment),
        }
    }
    (unc, segments)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_file_name_is_cut_at_either_separator() {
        assert_eq!(file_name("/usr/bin/node"), "node");
        assert_eq!(file_name(r"C:\Program Files\nodejs\node.exe"), "node.exe");
        assert_eq!(file_name("C:/tools/claude.exe"), "claude.exe");
        assert_eq!(file_name("/opt/tool/"), "tool");
        assert_eq!(file_name("qwen"), "qwen");
    }

    #[test]
    fn the_program_stem_drops_exe_in_any_case() {
        assert_eq!(program_stem(r"C:\nodejs\node.exe"), "node");
        assert_eq!(program_stem(r"C:\nodejs\NODE.EXE"), "NODE");
        assert_eq!(program_stem("/usr/bin/python3.12"), "python3.12");
        assert_eq!(program_stem(".exe"), "");
        assert_eq!(program_stem("я.exe"), "я");
    }

    #[test]
    fn a_windows_path_is_the_same_in_any_spelling() {
        let rule = r"C:\Users\me\AppData\Roaming\npm\node_modules\@anthropic-ai\claude-code\cli.js";
        // claude.cmd: %~dp0 уже кончается разделителем.
        assert!(same_windows_path(
            rule,
            r"C:\Users\me\AppData\Roaming\npm\\node_modules\@anthropic-ai\claude-code\cli.js"
        ));
        // claude.ps1 пишет прямые косые.
        assert!(same_windows_path(
            rule,
            "C:/Users/me/AppData/Roaming/npm/node_modules/@anthropic-ai/claude-code/cli.js"
        ));
        // Старый шим уходит в каталог выше и обратно.
        assert!(same_windows_path(
            rule,
            r"C:\Users\me\AppData\Roaming\npm\.\lib\..\node_modules\@anthropic-ai\claude-code\cli.js"
        ));
        assert!(same_windows_path(
            r"c:\tools\Claude.EXE",
            r"C:\Tools\claude.exe"
        ));
        assert!(same_windows_path(
            r"C:\Проекты\Цель.exe",
            r"c:\проекты\цель.EXE"
        ));
    }

    #[test]
    fn a_different_windows_path_stays_different() {
        assert!(!same_windows_path(r"C:\tools\cli.js", r"C:\other\cli.js"));
        assert!(!same_windows_path(r"C:\tools\cli.js", r"D:\tools\cli.js"));
        assert!(!same_windows_path(r"C:\tools\cli.js", r"C:\tools\cli.json"));
        assert!(!same_windows_path(r"C:\a\b\cli.js", r"C:\a\cli.js"));
        // UNC — не то же, что путь от корня текущего диска.
        assert!(!same_windows_path(
            r"\\server\share\cli.js",
            r"\server\share\cli.js"
        ));
        // Выше корня диска не подняться: `C:\..\x` — это `C:\x`, а не `x`.
        assert!(same_windows_path(r"C:\..\tools\cli.js", r"C:\tools\cli.js"));
    }

    #[test]
    fn a_store_app_is_the_same_program_after_an_update() {
        assert!(windows_across_versions(
            r"C:\Program Files\WindowsApps\Claude_6.28899.6.0_x64__pzs8sxrjxfjjc\app\Claude.exe",
            r"C:\Program Files\WindowsApps\Claude_6.30112.0.0_x64__pzs8sxrjxfjjc\app\claude.exe"
        ));
        // Squirrel и каталог с пробелом: версия — серия чисел через точку где угодно в сегменте.
        assert!(windows_across_versions(
            r"C:\Users\me\AppData\Local\Discord\app-1.0.9\Discord.exe",
            r"C:\Users\me\AppData\Local\Discord\app-1.0.10\Discord.exe"
        ));
        assert!(windows_across_versions(
            r"C:\Program Files\JetBrains\IntelliJ IDEA 2024.1\bin\idea64.exe",
            r"C:\Program Files\JetBrains\IntelliJ IDEA 2024.2.1\bin\idea64.exe"
        ));
        // Число до версии — не версия: `x64-` остаётся частью совпадающего начала.
        assert!(windows_across_versions(
            r"C:\tools\x64-1.2.3\tool.exe",
            r"C:\tools\x64-1.3.0\tool.exe"
        ));
    }

    #[test]
    fn a_unix_tool_is_the_same_program_after_an_update() {
        assert!(unix_across_versions(
            "/home/me/.nvm/versions/node/v20.11.0/lib/node_modules/@qwen-code/qwen-code/cli.js",
            "/home/me/.nvm/versions/node/v22.1.0/lib/node_modules/@qwen-code/qwen-code/cli.js"
        ));
        assert!(unix_across_versions(
            "/opt/discord/app-1.0.9/Discord",
            "/opt/discord/app-1.0.10/Discord"
        ));
    }

    #[test]
    fn a_different_program_is_not_another_version() {
        // Другой издатель, архитектура или пакет — другое приложение Store.
        let claude =
            r"C:\Program Files\WindowsApps\Claude_6.1.0.0_x64__pzs8sxrjxfjjc\app\Claude.exe";
        assert!(!windows_across_versions(
            claude,
            r"C:\Program Files\WindowsApps\Claude_6.2.0.0_x64__aaaaaaaaaaaaa\app\Claude.exe"
        ));
        assert!(!windows_across_versions(
            claude,
            r"C:\Program Files\WindowsApps\Claude_6.2.0.0_arm64__pzs8sxrjxfjjc\app\Claude.exe"
        ));
        assert!(!windows_across_versions(
            claude,
            r"C:\Program Files\WindowsApps\Other_6.2.0.0_x64__pzs8sxrjxfjjc\app\Claude.exe"
        ));
        // Имя файла — точно: соседняя версия интерпретатора — другая программа.
        assert!(!unix_across_versions(
            "/usr/bin/python3.11",
            "/usr/bin/python3.12"
        ));
        assert!(!unix_across_versions(
            "/home/me/.local/share/claude/versions/2.1.228",
            "/home/me/.local/share/claude/versions/2.1.300"
        ));
        // Одиночное число — не версия.
        assert!(!windows_across_versions(
            r"C:\Python311\python.exe",
            r"C:\Python312\python.exe"
        ));
        assert!(!unix_across_versions(
            "/snap/code/123/usr/bin/code",
            "/snap/code/124/usr/bin/code"
        ));
        // Различие не в версии, или в другом числе сегментов.
        assert!(!unix_across_versions("/opt/a/1.0/tool", "/opt/b/1.0/tool"));
        assert!(!unix_across_versions(
            "/opt/a/1.0/tool",
            "/opt/a/1.0/bin/tool"
        ));
        assert!(!unix_across_versions(
            "/opt/app-1.0/tool",
            "/opt/app-1.0-beta/tool"
        ));
    }

    #[test]
    fn a_relative_path_is_never_another_version() {
        assert!(!same_program_across_versions(
            "app-1.0/tool",
            "/opt/app-1.1/tool"
        ));
        assert!(!same_program_across_versions("tool", "tool"));
    }

    #[test]
    fn absolute_paths_of_both_systems_are_recognised() {
        assert!(is_absolute("/usr/local/bin/qwen"));
        assert!(is_absolute(r"C:\tools\cli.js"));
        assert!(is_absolute("d:/tools/cli.js"));
        assert!(is_absolute(r"\\server\share\cli.js"));

        assert!(!is_absolute("qwen"));
        assert!(!is_absolute(r"tools\cli.js"));
        assert!(!is_absolute("C:cli.js"));
        assert!(!is_absolute(""));
    }
}
