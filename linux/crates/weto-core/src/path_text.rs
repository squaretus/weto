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
