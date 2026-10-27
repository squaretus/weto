//! Настройки терминальной версии: тот же `Settings` и тот же TOML, что у окна,
//! но свой файл — `~/.config/weto-cli/config.toml`, от root — `/etc/weto/config.toml`.
//!
//! Команды правят файл, работающая охрана его перечитывает. Рассылки между
//! процессами нет и не нужно: охрана сверяет отметку файла раз в такт и парсит
//! TOML, только когда отметка сменилась.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::SystemTime;

use weto_config::settings::{Settings, SettingsError};
use weto_guard::controller::SettingsProviding;

/// Хранилище для команд: прочитать, поправить, сохранить.
pub struct Store {
    path: PathBuf,
    /// Файл читается всеми (`0644`) — системные настройки `/etc/weto`.
    public: bool,
}

impl Store {
    pub fn new(path: PathBuf) -> Store {
        Store {
            path,
            public: false,
        }
    }

    /// Системные настройки: `0644` после каждой записи. Процесс под root
    /// живёт с umask `077`, и временный файл без этого вышел бы `0600`.
    pub fn public(path: PathBuf) -> Store {
        Store { path, public: true }
    }

    pub fn load(&self) -> Result<Settings, SettingsError> {
        Settings::load(&self.path)
    }

    /// Правка с подъёмом ревизии — как правка из окна: по ревизии охрана
    /// понимает, что прежний вердикт больше не свеж, и пересчитывает решение.
    /// Сохраняется только принятая правка: отказ файла не трогает.
    pub fn edit<T, E>(
        &self,
        change: impl FnOnce(&mut Settings) -> Result<T, E>,
    ) -> Result<Result<T, E>, SettingsError> {
        self.save_with(change, true)
    }

    /// Правка без ревизии — для того, что решения политики не меняет: потолок
    /// паузы. Ревизия обесценивала бы вердикт и уводила охрану в «Проверку».
    pub fn edit_untracked<T, E>(
        &self,
        change: impl FnOnce(&mut Settings) -> Result<T, E>,
    ) -> Result<Result<T, E>, SettingsError> {
        self.save_with(change, false)
    }

    fn save_with<T, E>(
        &self,
        change: impl FnOnce(&mut Settings) -> Result<T, E>,
        tracked: bool,
    ) -> Result<Result<T, E>, SettingsError> {
        let mut settings = self.load()?;
        let answer = change(&mut settings);
        if answer.is_ok() {
            if tracked {
                settings.revision += 1;
            }
            settings.save(&self.path)?;
            if self.public {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&self.path, std::fs::Permissions::from_mode(0o644))
                    .map_err(|error| SettingsError::Write(error.to_string()))?;
            }
        }
        Ok(answer)
    }
}

/// Отметка файла настроек: время изменения, размер и inode. Inode обязателен:
/// сохранение идёт через temp + rename, и две правки в одну и ту же
/// наносекунду файловой системы с грубыми часами иначе сливались бы в одну.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Stamp {
    modified: Option<SystemTime>,
    len: u64,
    inode: u64,
}

fn stamp(path: &Path) -> Option<Stamp> {
    use std::os::unix::fs::MetadataExt;
    let metadata = std::fs::metadata(path).ok()?;
    Some(Stamp {
        modified: metadata.modified().ok(),
        len: metadata.len(),
        inode: metadata.ino(),
    })
}

/// Чем кончилась сверка файла.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Reload {
    Unchanged,
    Reloaded,
    /// Файл испорчен: охрана продолжает на прежних настройках — падать из-за
    /// правки руками она не имеет права, ей надо охранять.
    Failed(String),
}

/// Настройки работающей охраны: в памяти, с перечитыванием по отметке файла.
pub struct WatchedSettings {
    path: PathBuf,
    state: Mutex<Watched>,
}

struct Watched {
    settings: Settings,
    stamp: Option<Stamp>,
}

impl WatchedSettings {
    pub fn open(path: PathBuf) -> Result<Arc<WatchedSettings>, SettingsError> {
        let stamp = stamp(&path);
        let settings = Settings::load(&path)?;
        Ok(Arc::new(WatchedSettings {
            path,
            state: Mutex::new(Watched { settings, stamp }),
        }))
    }

    pub fn current(&self) -> Settings {
        self.state.lock().expect("настройки").settings.clone()
    }

    /// Сверка отметки и, если она сменилась, разбор файла. Испорченный файл
    /// отметку всё равно запоминает: иначе ошибка печаталась бы каждый такт.
    pub fn reload_if_changed(&self) -> Reload {
        let fresh = stamp(&self.path);
        let mut state = self.state.lock().expect("настройки");
        if fresh == state.stamp {
            return Reload::Unchanged;
        }
        state.stamp = fresh;
        match Settings::load(&self.path) {
            Ok(settings) => {
                state.settings = settings;
                Reload::Reloaded
            }
            Err(error) => Reload::Failed(error.to_string()),
        }
    }
}

/// Источник настроек для охраны.
pub struct WatchedSource(pub Arc<WatchedSettings>);

impl SettingsProviding for WatchedSource {
    fn settings(&self) -> Settings {
        self.0.current()
    }
}
