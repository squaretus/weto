//! Автозапуск — ровно одно значение в `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.
//!
//! Одно место на всех: тумблер в настройках, установщик и деинсталлятор
//! работают с этим же значением. Путь — стабильный `Weto.exe` установки
//! (`Paths::launcher`), а не путь текущего процесса: при обновлении процесс
//! может идти из другого места.

use windows_sys::Win32::Foundation::{ERROR_FILE_NOT_FOUND, ERROR_SUCCESS};
use windows_sys::Win32::System::Registry::{
    RegCloseKey, RegDeleteValueW, RegOpenKeyExW, RegQueryValueExW, RegSetValueExW, HKEY,
    HKEY_CURRENT_USER, KEY_QUERY_VALUE, KEY_SET_VALUE, REG_SZ,
};

use crate::wide;

const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";

/// Имя значения у приложения.
pub const VALUE_NAME: &str = "Weto";

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum AutostartError {
    #[error("ключ автозапуска не открылся: код {0}")]
    Open(u32),
    #[error("автозапуск не записался: код {0}")]
    Write(u32),
}

pub struct RunKeyAutostart {
    value: Vec<u16>,
}

impl RunKeyAutostart {
    /// Значение с заданным именем: приложение — `VALUE_NAME`, тесты — своё.
    pub fn new(value_name: &str) -> RunKeyAutostart {
        RunKeyAutostart {
            value: wide::null_terminated(value_name),
        }
    }

    /// Включить: команда запуска — путь в кавычках (в нём бывают пробелы).
    pub fn enable(&self, launcher: &std::path::Path) -> Result<(), AutostartError> {
        let command = wide::null_terminated(&format!("\"{}\"", launcher.display()));
        let key = open(KEY_SET_VALUE)?;
        // SAFETY: строка с нулём на конце, длина в байтах включает нуль.
        let status = unsafe {
            RegSetValueExW(
                key,
                self.value.as_ptr(),
                0,
                REG_SZ,
                command.as_ptr().cast(),
                (command.len() * 2) as u32,
            )
        };
        close(key);
        if status != ERROR_SUCCESS {
            return Err(AutostartError::Write(status));
        }
        Ok(())
    }

    /// Выключить. Значения и так нет — тоже успех.
    pub fn disable(&self) -> Result<(), AutostartError> {
        let key = open(KEY_SET_VALUE)?;
        // SAFETY: имя с нулём на конце.
        let status = unsafe { RegDeleteValueW(key, self.value.as_ptr()) };
        close(key);
        if status != ERROR_SUCCESS && status != ERROR_FILE_NOT_FOUND {
            return Err(AutostartError::Write(status));
        }
        Ok(())
    }

    /// Команда запуска, если автозапуск включён.
    pub fn command(&self) -> Option<String> {
        let key = open(KEY_QUERY_VALUE).ok()?;
        let mut buffer = vec![0u16; 1024];
        let mut size = (buffer.len() * 2) as u32;
        let mut kind = 0u32;
        // SAFETY: буфер наш, `size` — его ёмкость в байтах.
        let status = unsafe {
            RegQueryValueExW(
                key,
                self.value.as_ptr(),
                std::ptr::null(),
                &mut kind,
                buffer.as_mut_ptr().cast(),
                &mut size,
            )
        };
        close(key);
        (status == ERROR_SUCCESS && kind == REG_SZ)
            .then(|| wide::until_null(&buffer[..size as usize / 2]))
    }
}

fn open(access: u32) -> Result<HKEY, AutostartError> {
    let path = wide::null_terminated(RUN_KEY);
    let mut key: HKEY = std::ptr::null_mut();
    // SAFETY: путь с нулём на конце; ключ закрывается вызывающим.
    let status = unsafe { RegOpenKeyExW(HKEY_CURRENT_USER, path.as_ptr(), 0, access, &mut key) };
    if status != ERROR_SUCCESS {
        return Err(AutostartError::Open(status));
    }
    Ok(key)
}

fn close(key: HKEY) {
    // SAFETY: ключ открыт `open` и закрывается ровно раз.
    unsafe { RegCloseKey(key) };
}
