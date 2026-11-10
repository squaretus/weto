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
pub fn same_path(left: &str, right: &str) -> bool {
    if cfg!(windows) {
        left.eq_ignore_ascii_case(right)
    } else {
        left == right
    }
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
