//! Хранилище токена ipinfo.
//!
//! В файл настроек токен не попадает намеренно: конфиг читается любым процессом
//! пользователя и уезжает в бэкапы. То же решение, что на macOS, где токен живёт
//! в Keychain, а не в `UserDefaults`.
//!
//! Здесь пока одна реализация — файл с правами `0600`. Secret Service по D-Bus
//! появится вместе с UI: проверить его можно только в живой сессии рабочего
//! стола, а выдавать непроверенную интеграцию за работающую нельзя.

use std::fs;
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

#[derive(Debug, thiserror::Error)]
pub enum SecretError {
    #[error("не записать секрет: {0}")]
    Write(String),
    #[error("не прочитать секрет: {0}")]
    Read(String),
}

/// Границы возвращают `Result`, а не `bool`.
///
/// Тихая ошибка записи выдавала бы токен за сохранённый — на macOS этот урок
/// уже оплачен, и повторять его незачем.
pub trait SecretStoring: Send + Sync {
    fn load(&self) -> Result<Option<String>, SecretError>;
    fn save(&self, token: &str) -> Result<(), SecretError>;
    fn delete(&self) -> Result<(), SecretError>;
}

pub struct FileSecretStore {
    path: PathBuf,
}

impl FileSecretStore {
    pub fn new(path: PathBuf) -> FileSecretStore {
        FileSecretStore { path }
    }
}

impl SecretStoring for FileSecretStore {
    fn load(&self) -> Result<Option<String>, SecretError> {
        match fs::read_to_string(&self.path) {
            Ok(text) => Ok(Some(text.trim().to_string()).filter(|t| !t.is_empty())),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(SecretError::Read(error.to_string())),
        }
    }

    fn save(&self, token: &str) -> Result<(), SecretError> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent).map_err(|e| SecretError::Write(e.to_string()))?;
            harden(parent)?;
        }

        // Режим задаётся при создании, а не после записи: иначе между
        // созданием файла и chmod существует окно, в котором секрет читаем всем.
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&self.path)
            .map_err(|e| SecretError::Write(e.to_string()))?;

        file.write_all(token.as_bytes())
            .map_err(|e| SecretError::Write(e.to_string()))?;

        // Файл мог существовать раньше с другими правами: create их не меняет.
        fs::set_permissions(&self.path, fs::Permissions::from_mode(0o600))
            .map_err(|e| SecretError::Write(e.to_string()))
    }

    fn delete(&self) -> Result<(), SecretError> {
        match fs::remove_file(&self.path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(SecretError::Write(error.to_string())),
        }
    }
}

fn harden(directory: &Path) -> Result<(), SecretError> {
    fs::set_permissions(directory, fs::Permissions::from_mode(0o700))
        .map_err(|e| SecretError::Write(e.to_string()))
}
