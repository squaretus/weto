//! Раскладка версий на диске и атомарная подмена текущей.
//!
//! ```text
//! ~/.local/share/weto/
//! ├── 0.4.1/            распакованный релиз
//! ├── 0.4.2/
//! └── current -> 0.4.2
//! ~/.local/bin/weto -> ~/.local/share/weto/current/bin/weto
//! ```
//!
//! Обновление — распаковка нового каталога рядом и подмена симлинка. Root
//! не нужен: всё лежит в домашнем каталоге, и потому демона с правами,
//! как на macOS, здесь нет вовсе.

use std::path::{Path, PathBuf};

use crate::version::Version;

#[derive(Debug, thiserror::Error)]
pub enum LayoutError {
    #[error("не переключить версию: {0}")]
    Activate(String),
    #[error("не убрать старую версию: {0}")]
    Prune(String),
}

pub struct Layout {
    root: PathBuf,
}

impl Layout {
    /// Корень — `$XDG_DATA_HOME/weto`.
    pub fn new(data_dir: PathBuf) -> Layout {
        Layout { root: data_dir }
    }

    pub fn install_dir(&self, version: &Version) -> PathBuf {
        self.root.join(version.to_string())
    }

    pub fn current_symlink(&self) -> PathBuf {
        self.root.join("current")
    }

    pub fn current_version(&self) -> Option<Version> {
        let target = std::fs::read_link(self.current_symlink()).ok()?;
        Version::parse(target.file_name()?.to_str()?)
    }

    /// Переставляет `current` на указанную версию.
    ///
    /// Через временный симлинк и `rename`, а не `unlink` + `symlink`: во втором
    /// случае существует окно, в котором приложения на диске нет вовсе, — и если
    /// в это окно попадёт запуск из ярлыка, пользователь увидит «файл не найден».
    pub fn activate(&self, version: &Version) -> Result<(), LayoutError> {
        let target = self.install_dir(version);
        if !target.is_dir() {
            return Err(LayoutError::Activate(format!(
                "каталога {} не существует",
                target.display()
            )));
        }

        let temporary = self.root.join(".current.new");
        let _ = std::fs::remove_file(&temporary);
        std::os::unix::fs::symlink(&target, &temporary)
            .map_err(|e| LayoutError::Activate(e.to_string()))?;

        std::fs::rename(&temporary, self.current_symlink())
            .map_err(|e| LayoutError::Activate(e.to_string()))
    }

    pub fn installed_versions(&self) -> Vec<Version> {
        let mut versions: Vec<Version> = std::fs::read_dir(&self.root)
            .into_iter()
            .flatten()
            .flatten()
            .filter(|entry| entry.path().is_dir())
            .filter_map(|entry| Version::parse(entry.file_name().to_str()?))
            .collect();
        versions.sort();
        versions
    }

    /// Оставляет текущую версию и `keep` предыдущих.
    ///
    /// Одна предыдущая нужна не ради экономии трафика, а ради отката: если новая
    /// версия не стартует, вернуться будет некуда.
    pub fn prune(&self, keep: usize) -> Result<(), LayoutError> {
        let current = self.current_version();
        let mut versions = self.installed_versions();
        versions.reverse();

        let mut kept = 0usize;
        for version in versions {
            if Some(version) == current {
                continue;
            }
            if kept < keep {
                kept += 1;
                continue;
            }
            std::fs::remove_dir_all(self.install_dir(&version))
                .map_err(|e| LayoutError::Prune(e.to_string()))?;
        }
        Ok(())
    }

    /// Версия, на которую можно откатиться, — ближайшая ниже текущей.
    pub fn previous_version(&self) -> Option<Version> {
        let current = self.current_version()?;
        self.installed_versions()
            .into_iter()
            .rfind(|version| *version < current)
    }
}

/// Куда распаковывать: временный каталог рядом с целевым, а не в `/tmp`.
///
/// Рядом — потому что `rename` работает только в пределах файловой системы,
/// а `/tmp` часто отдельный tmpfs; перенос через границу превратился бы
/// в копирование с окном, в котором каталог наполовину собран.
pub fn staging_dir(target: &Path) -> PathBuf {
    let mut name = target.file_name().unwrap_or_default().to_os_string();
    name.push(".unpacking");
    target.with_file_name(name)
}
