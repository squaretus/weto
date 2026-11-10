//! Ярлык Windows (`.lnk`, формат MS-SHLLINK) — куда он ведёт.
//!
//! Аналог `.desktop` на Linux: цель, выбранная из меню «Пуск», хранится
//! ярлыком, а программа ищется по нему заново при каждом разрешении. Так цель
//! переживает обновление, меняющее версионный путь программы, а ядро отличает
//! приложение от команды (`presentation::is_command_line_target`).
//!
//! Разбор свой, без COM `IShellLink`: формат открыт, разбор чистый и проверяется
//! тестами где угодно, а `windows-sys` COM-интерфейсов не несёт. Путь берётся
//! в порядке надёжности:
//! 1. блок переменных окружения (`%LOCALAPPDATA%\Programs\…`) — его пишет
//!    установщик, когда путь лежит под профилем;
//! 2. `LocalBasePath` из `LinkInfo` (Unicode, если есть, иначе ANSI) плюс
//!    `CommonPathSuffix`;
//! 3. `RELATIVE_PATH` относительно каталога ярлыка.
//!
//! Ярлыки без пути к файлу (только список идентификаторов оболочки — «Этот
//! компьютер», приложения Магазина, «объявленные» ярлыки MSI) целью быть
//! не могут: программы за ними нет.

use std::path::Path;

const HEADER_SIZE: usize = 0x4C;

const HAS_LINK_TARGET_ID_LIST: u32 = 0x1;
const HAS_LINK_INFO: u32 = 0x2;
const HAS_NAME: u32 = 0x4;
const HAS_RELATIVE_PATH: u32 = 0x8;
const IS_UNICODE: u32 = 0x80;
const HAS_EXP_STRING: u32 = 0x200;

const VOLUME_ID_AND_LOCAL_BASE_PATH: u32 = 0x1;
const ENVIRONMENT_VARIABLE_BLOCK: u32 = 0xA000_0001;

/// Что записано в ярлыке о его программе, до раскрытия переменных.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Shortcut {
    /// Путь из блока переменных окружения, как записан: `%LOCALAPPDATA%\…`.
    pub environment_target: Option<String>,
    /// `LocalBasePath` + `CommonPathSuffix`.
    pub local_path: Option<String>,
    /// `RELATIVE_PATH` — от каталога ярлыка.
    pub relative_path: Option<String>,
}

impl Shortcut {
    /// Путь программы: переменные раскрыты `expand`, относительный — от `directory`.
    pub fn target(
        &self,
        directory: &Path,
        expand: &dyn Fn(&str) -> Option<String>,
    ) -> Option<String> {
        if let Some(path) = self.environment_target.as_deref().and_then(expand) {
            return Some(path);
        }
        if let Some(path) = &self.local_path {
            return Some(path.clone());
        }
        self.relative_path
            .as_deref()
            .map(|relative| directory.join(relative).to_string_lossy().into_owned())
    }
}

/// Разбор файла ярлыка. `None` — это не ярлык или он обрезан.
pub fn parse(bytes: &[u8]) -> Option<Shortcut> {
    if u32_at(bytes, 0)? as usize != HEADER_SIZE {
        return None;
    }
    let flags = u32_at(bytes, 0x14)?;
    let unicode = flags & IS_UNICODE != 0;
    let mut offset = HEADER_SIZE;

    if flags & HAS_LINK_TARGET_ID_LIST != 0 {
        offset += 2 + u16_at(bytes, offset)? as usize;
    }

    let mut shortcut = Shortcut::default();
    if flags & HAS_LINK_INFO != 0 {
        let info = bytes.get(offset..)?;
        let size = u32_at(info, 0)? as usize;
        shortcut.local_path = local_base_path(info.get(..size)?);
        offset += size;
    }

    // Строки идут в порядке NAME, RELATIVE_PATH, WORKING_DIR, ARGUMENTS,
    // ICON_LOCATION; нужен только относительный путь, остальные пропускаются.
    for (flag, keep) in [
        (HAS_NAME, false),
        (HAS_RELATIVE_PATH, true),
        (0x10, false),
        (0x20, false),
        (0x40, false),
    ] {
        if flags & flag == 0 {
            continue;
        }
        let count = u16_at(bytes, offset)? as usize;
        let length = if unicode { count * 2 } else { count };
        let text = bytes.get(offset + 2..offset + 2 + length)?;
        if keep {
            shortcut.relative_path = Some(if unicode { utf16(text) } else { ansi(text) });
        }
        offset += 2 + length;
    }

    if flags & HAS_EXP_STRING != 0 {
        shortcut.environment_target = environment_block(bytes.get(offset..)?);
    }
    Some(shortcut)
}

/// `LocalBasePath` из структуры `LinkInfo`: Unicode-вариант, если заголовок
/// его объявляет, иначе ANSI; плюс общий суффикс пути.
fn local_base_path(info: &[u8]) -> Option<String> {
    let header_size = u32_at(info, 4)? as usize;
    let info_flags = u32_at(info, 8)?;
    if info_flags & VOLUME_ID_AND_LOCAL_BASE_PATH == 0 {
        return None;
    }
    let (base, suffix) = if header_size >= 0x24 {
        let base = u32_at(info, 0x1C)? as usize;
        let suffix = u32_at(info, 0x20)? as usize;
        (
            utf16_until_nul(info.get(base..)?),
            utf16_until_nul(info.get(suffix..)?),
        )
    } else {
        let base = u32_at(info, 0x10)? as usize;
        let suffix = u32_at(info, 0x18)? as usize;
        (
            ansi_until_nul(info.get(base..)?),
            ansi_until_nul(info.get(suffix..)?),
        )
    };
    (!base.is_empty()).then(|| base + &suffix)
}

/// Блок `EnvironmentVariableDataBlock` среди дополнительных данных.
fn environment_block(mut extra: &[u8]) -> Option<String> {
    loop {
        let size = u32_at(extra, 0)? as usize;
        if size < 8 {
            return None;
        }
        if u32_at(extra, 4)? == ENVIRONMENT_VARIABLE_BLOCK {
            let block = extra.get(..size)?;
            // TargetAnsi — 260 байт, TargetUnicode — 520 байт после него.
            let unicode = utf16_until_nul(block.get(8 + 260..8 + 260 + 520)?);
            if !unicode.is_empty() {
                return Some(unicode);
            }
            let ansi = ansi_until_nul(block.get(8..8 + 260)?);
            return (!ansi.is_empty()).then_some(ansi);
        }
        extra = extra.get(size..)?;
    }
}

/// Раскрыть `%ИМЯ%` значениями из `lookup`. Неизвестная переменная — `None`:
/// путь с ней никуда не ведёт.
pub fn expand_variables(text: &str, lookup: &dyn Fn(&str) -> Option<String>) -> Option<String> {
    let mut result = String::new();
    let mut rest = text;
    while let Some(start) = rest.find('%') {
        result.push_str(&rest[..start]);
        let after = &rest[start + 1..];
        let end = after.find('%')?;
        result.push_str(&lookup(&after[..end])?);
        rest = &after[end + 1..];
    }
    result.push_str(rest);
    Some(result)
}

/// Ярлык по пути к файлу: куда ведёт сейчас. `None` — файла нет или пути в нём нет.
pub fn resolve(path: &Path) -> Option<String> {
    let bytes = std::fs::read(path).ok()?;
    let shortcut = parse(&bytes)?;
    shortcut.target(path.parent()?, &|text| {
        expand_variables(text, &|name| std::env::var(name).ok())
    })
}

/// Запись настроек — ярлык (`.lnk` в любом регистре).
pub fn is_shortcut(entry: &str) -> bool {
    entry.to_ascii_lowercase().ends_with(".lnk")
}

fn u16_at(bytes: &[u8], offset: usize) -> Option<u16> {
    Some(u16::from_le_bytes(
        bytes.get(offset..offset + 2)?.try_into().ok()?,
    ))
}

fn u32_at(bytes: &[u8], offset: usize) -> Option<u32> {
    Some(u32::from_le_bytes(
        bytes.get(offset..offset + 4)?.try_into().ok()?,
    ))
}

fn utf16(bytes: &[u8]) -> String {
    let units: Vec<u16> = bytes
        .chunks_exact(2)
        .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
        .collect();
    String::from_utf16_lossy(&units)
}

fn utf16_until_nul(bytes: &[u8]) -> String {
    let units: Vec<u16> = bytes
        .chunks_exact(2)
        .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
        .take_while(|unit| *unit != 0)
        .collect();
    String::from_utf16_lossy(&units)
}

/// ANSI-строки ярлыка — в кодовой странице системы; путь из них берётся,
/// только когда Unicode-варианта нет, а не-ASCII в нём читается с потерями.
fn ansi(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

fn ansi_until_nul(bytes: &[u8]) -> String {
    let end = bytes
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(bytes.len());
    ansi(&bytes[..end])
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Собирает ярлык по формату: заголовок, `LinkInfo` с путём, строки, блоки.
    struct Builder {
        local_path: Option<String>,
        unicode_info: bool,
        relative_path: Option<String>,
        environment: Option<String>,
        id_list: bool,
    }

    impl Builder {
        fn new() -> Builder {
            Builder {
                local_path: None,
                unicode_info: true,
                relative_path: None,
                environment: None,
                id_list: true,
            }
        }

        fn build(&self) -> Vec<u8> {
            let mut flags = IS_UNICODE;
            if self.id_list {
                flags |= HAS_LINK_TARGET_ID_LIST;
            }
            if self.local_path.is_some() {
                flags |= HAS_LINK_INFO;
            }
            if self.relative_path.is_some() {
                flags |= HAS_RELATIVE_PATH;
            }
            if self.environment.is_some() {
                flags |= HAS_EXP_STRING;
            }
            let mut bytes = vec![0u8; HEADER_SIZE];
            bytes[0..4].copy_from_slice(&(HEADER_SIZE as u32).to_le_bytes());
            bytes[0x14..0x18].copy_from_slice(&flags.to_le_bytes());

            if self.id_list {
                // Список идентификаторов — произвольные байты, разбор их пропускает.
                bytes.extend_from_slice(&6u16.to_le_bytes());
                bytes.extend_from_slice(&[4, 0, 0xAA, 0xBB, 0, 0]);
            }
            if let Some(path) = &self.local_path {
                bytes.extend(link_info(path, self.unicode_info));
            }
            if let Some(relative) = &self.relative_path {
                let units: Vec<u16> = relative.encode_utf16().collect();
                bytes.extend_from_slice(&(units.len() as u16).to_le_bytes());
                for unit in units {
                    bytes.extend_from_slice(&unit.to_le_bytes());
                }
            }
            if let Some(target) = &self.environment {
                let mut block = vec![0u8; 0x314];
                block[0..4].copy_from_slice(&0x314u32.to_le_bytes());
                block[4..8].copy_from_slice(&ENVIRONMENT_VARIABLE_BLOCK.to_le_bytes());
                for (index, unit) in target.encode_utf16().enumerate() {
                    let at = 8 + 260 + index * 2;
                    block[at..at + 2].copy_from_slice(&unit.to_le_bytes());
                }
                bytes.extend(block);
            }
            bytes.extend_from_slice(&0u32.to_le_bytes()); // TerminalBlock
            bytes
        }
    }

    fn link_info(path: &str, unicode: bool) -> Vec<u8> {
        let header: usize = if unicode { 0x24 } else { 0x1C };
        let mut info = vec![0u8; header];
        info[4..8].copy_from_slice(&(header as u32).to_le_bytes());
        info[8..12].copy_from_slice(&VOLUME_ID_AND_LOCAL_BASE_PATH.to_le_bytes());
        // VolumeID: минимальная структура, разбор её не читает.
        let volume = info.len();
        info.extend_from_slice(&[0x11, 0, 0, 0]);
        info.extend_from_slice(&[0; 13]);
        info[0x0C..0x10].copy_from_slice(&(volume as u32).to_le_bytes());
        let ansi_base = info.len();
        info.extend_from_slice(path.as_bytes());
        info.push(0);
        let ansi_suffix = info.len();
        info.push(0);
        info[0x10..0x14].copy_from_slice(&(ansi_base as u32).to_le_bytes());
        info[0x18..0x1C].copy_from_slice(&(ansi_suffix as u32).to_le_bytes());
        if unicode {
            let base = info.len();
            for unit in path.encode_utf16() {
                info.extend_from_slice(&unit.to_le_bytes());
            }
            info.extend_from_slice(&[0, 0]);
            let suffix = info.len();
            info.extend_from_slice(&[0, 0]);
            info[0x1C..0x20].copy_from_slice(&(base as u32).to_le_bytes());
            info[0x20..0x24].copy_from_slice(&(suffix as u32).to_le_bytes());
        }
        let size = info.len() as u32;
        info[0..4].copy_from_slice(&size.to_le_bytes());
        info
    }

    fn no_variables(_: &str) -> Option<String> {
        None
    }

    #[test]
    fn a_shortcut_names_its_program_by_the_local_path() {
        let mut builder = Builder::new();
        builder.local_path = Some(r"C:\Program Files\Happ\Happ.exe".into());

        let shortcut = parse(&builder.build()).unwrap();

        assert_eq!(
            shortcut
                .target(Path::new(r"C:\Start"), &no_variables)
                .as_deref(),
            Some(r"C:\Program Files\Happ\Happ.exe")
        );
    }

    /// Не-ASCII имя читается из Unicode-варианта, а не из ANSI с потерями.
    #[test]
    fn the_unicode_path_wins_over_the_ansi_one() {
        let mut builder = Builder::new();
        builder.local_path = Some(r"C:\Программы\Клиент.exe".into());

        let shortcut = parse(&builder.build()).unwrap();

        assert_eq!(
            shortcut.local_path.as_deref(),
            Some(r"C:\Программы\Клиент.exe")
        );
    }

    #[test]
    fn an_old_link_info_without_unicode_still_gives_the_path() {
        let mut builder = Builder::new();
        builder.local_path = Some(r"C:\Tools\tool.exe".into());
        builder.unicode_info = false;

        assert_eq!(
            parse(&builder.build()).unwrap().local_path.as_deref(),
            Some(r"C:\Tools\tool.exe")
        );
    }

    /// Путь под профилем установщик пишет переменными: он и решает, а не
    /// путь машины, на которой ярлык создан.
    #[test]
    fn the_environment_block_wins_and_is_expanded() {
        let mut builder = Builder::new();
        builder.local_path = Some(r"C:\Users\builder\AppData\Local\Programs\weto\Weto.exe".into());
        builder.environment = Some(r"%LOCALAPPDATA%\Programs\weto\Weto.exe".into());

        let shortcut = parse(&builder.build()).unwrap();
        let lookup =
            |name: &str| (name == "LOCALAPPDATA").then(|| r"C:\Users\u\AppData\Local".to_string());

        assert_eq!(
            shortcut
                .target(Path::new(r"C:\Start"), &|text| expand_variables(
                    text, &lookup
                ))
                .as_deref(),
            Some(r"C:\Users\u\AppData\Local\Programs\weto\Weto.exe")
        );
    }

    #[test]
    fn a_relative_path_is_taken_from_the_shortcut_folder() {
        let mut builder = Builder::new();
        builder.relative_path = Some(r"..\bin\tool.exe".into());

        let shortcut = parse(&builder.build()).unwrap();

        assert_eq!(
            shortcut.target(Path::new("/start"), &no_variables),
            Some(
                Path::new("/start")
                    .join(r"..\bin\tool.exe")
                    .to_string_lossy()
                    .into_owned()
            )
        );
    }

    /// «Этот компьютер», приложения Магазина: пути к файлу нет — целью быть не может.
    #[test]
    fn a_shell_only_shortcut_has_no_program() {
        let shortcut = parse(&Builder::new().build()).unwrap();

        assert_eq!(shortcut.target(Path::new(r"C:\Start"), &no_variables), None);
    }

    #[test]
    fn not_a_shortcut_is_not_parsed() {
        assert_eq!(parse(b"MZ\x90\x00"), None);
        assert_eq!(parse(&[]), None);
        let mut truncated = Builder::new();
        truncated.local_path = Some(r"C:\a.exe".into());
        let bytes = truncated.build();
        assert_eq!(parse(&bytes[..HEADER_SIZE + 4]), None);
    }

    #[test]
    fn an_unknown_variable_leads_nowhere() {
        let lookup = |name: &str| (name == "A").then(|| "x".to_string());
        assert_eq!(expand_variables(r"%A%\b", &lookup).as_deref(), Some(r"x\b"));
        assert_eq!(expand_variables(r"%B%\b", &lookup), None);
        assert_eq!(expand_variables(r"%A\b", &lookup), None);
    }

    #[test]
    fn shortcuts_are_recognised_in_any_case() {
        assert!(is_shortcut(r"C:\Start\Happ.lnk"));
        assert!(is_shortcut(r"C:\Start\Happ.LNK"));
        assert!(!is_shortcut(r"C:\Start\Happ.exe"));
    }
}
