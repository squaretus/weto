//! Скачивание, проверка и установка обновления.
//!
//! Порядок: проверить адрес → скачать → распаковать рядом → переставить
//! симлинк. Адрес проверяется до всякого запроса — он приходит из сети,
//! и подставить туда чужой хост первым делом попробует подменивший ответ.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use crate::layout::{staging_dir, Layout};
use crate::version::Version;

/// Фаза установки. Незнакомый код на macOS читается как «идёт установка»,
/// а не как «простой»; здесь фаза своя и типизирована, но правило то же:
/// молчание не выдаётся за успех.
#[derive(Debug, Clone, PartialEq)]
pub enum Phase {
    Idle,
    Downloading { fraction: f32 },
    Unpacking,
    Restarting,
    Failed(String),
}

#[derive(Debug, thiserror::Error)]
pub enum InstallError {
    #[error("недоверенный источник: {0}")]
    UntrustedHost(String),
    #[error("скачивание не удалось: {0}")]
    Download(String),
    #[error("распаковка не удалась: {0}")]
    Unpack(String),
    #[error("не переключить версию: {0}")]
    Activate(String),
}

/// Хосты доставки релизов GitHub. Список тот же, что в `ReleasePackageURL`
/// на macOS, и расходиться они не имеют права: `release-assets.githubusercontent.com` —
/// это то, куда GitHub редиректит скачивание, и без него не работает загрузка вовсе.
pub const ALLOWED_HOSTS: [&str; 3] = [
    "github.com",
    "objects.githubusercontent.com",
    "release-assets.githubusercontent.com",
];

/// Проверка адреса, по которому пойдёт загрузка.
///
/// Адрес приходит из сети (ответ GitHub API), поэтому подставлять его
/// в загрузчик без проверки нельзя: подменённый ответ увёл бы установку
/// на чужой файл. Пускаем только https, только хосты доставки релизов GitHub
/// и только ожидаемое расширение — как на macOS.
///
/// Хост сверяется целиком, а не префиксом строки: `https://github.com@evil.com/`
/// начинается не с чужого хоста, но ведёт именно на него.
pub fn is_trusted_url(url: &str, expected_suffix: &str) -> bool {
    let Some(rest) = url.strip_prefix("https://") else {
        return false;
    };
    let (authority, path) = match rest.split_once('/') {
        Some((authority, path)) => (authority, path),
        None => return false,
    };

    ALLOWED_HOSTS.contains(&authority) && path.ends_with(expected_suffix)
}

pub struct Installer {
    layout: Layout,
    cache_dir: PathBuf,
    progress: Arc<AtomicU64>,
}

impl Installer {
    pub fn new(layout: Layout, cache_dir: PathBuf) -> Installer {
        Installer {
            layout,
            cache_dir,
            progress: Arc::new(AtomicU64::new(0)),
        }
    }

    /// Доля скачанного в тысячных. Честная только на загрузке: распаковка
    /// у нас быстрая, а притворяться, что мы знаем её ход, незачем.
    pub fn progress(&self) -> f32 {
        self.progress.load(Ordering::Relaxed) as f32 / 1000.0
    }

    pub fn install(&self, version: &Version, archive_url: &str) -> Result<(), InstallError> {
        if !is_trusted_url(archive_url, ".tar.zst") {
            return Err(InstallError::UntrustedHost(archive_url.to_string()));
        }

        // Каталог загрузки закрыт от чужих глаз: между скачиванием и распаковкой
        // файл не должен быть доступен на запись никому, кроме нас.
        std::fs::create_dir_all(&self.cache_dir)
            .map_err(|e| InstallError::Download(e.to_string()))?;
        harden(&self.cache_dir);

        let archive = self.cache_dir.join(format!("weto-{version}.tar.zst"));
        let result = self.run(version, archive_url, &archive);

        // Скачанное не остаётся на диске ни при успехе, ни при провале.
        let _ = std::fs::remove_file(&archive);
        result
    }

    fn run(
        &self,
        version: &Version,
        archive_url: &str,
        archive: &Path,
    ) -> Result<(), InstallError> {
        self.progress.store(0, Ordering::Relaxed);
        download(archive_url, archive, Some(&self.progress))
            .map_err(|e| InstallError::Download(e.to_string()))?;

        let target = self.layout.install_dir(version);
        let staging = staging_dir(&target);
        let _ = std::fs::remove_dir_all(&staging);
        std::fs::create_dir_all(&staging).map_err(|e| InstallError::Unpack(e.to_string()))?;

        unpack(archive, &staging).map_err(|e| InstallError::Unpack(e.to_string()))?;

        // Архив разворачивается в каталог weto-<version>/ — поднимаем его
        // содержимое на уровень версии.
        let inner = staging.join(format!("weto-{version}"));
        let source = if inner.is_dir() {
            inner
        } else {
            staging.clone()
        };

        let _ = std::fs::remove_dir_all(&target);
        std::fs::rename(&source, &target).map_err(|e| InstallError::Unpack(e.to_string()))?;
        let _ = std::fs::remove_dir_all(&staging);

        self.layout
            .activate(version)
            .map_err(|e| InstallError::Activate(e.to_string()))?;
        let _ = self.layout.prune(1);

        Ok(())
    }
}

fn harden(directory: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o700));
}

fn download(url: &str, into: &Path, progress: Option<&AtomicU64>) -> std::io::Result<()> {
    use std::os::unix::fs::OpenOptionsExt;

    let response = ureq::get(url)
        .call()
        .map_err(|e| std::io::Error::other(e.to_string()))?;

    let total: u64 = response
        .header("Content-Length")
        .and_then(|value| value.parse().ok())
        .unwrap_or(0);

    let mut reader = response.into_reader();
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(into)?;

    let mut buffer = [0u8; 64 * 1024];
    let mut written: u64 = 0;
    loop {
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        std::io::Write::write_all(&mut file, &buffer[..read])?;
        written += read as u64;

        if let (Some(progress), true) = (progress, total > 0) {
            progress.store(written * 1000 / total, Ordering::Relaxed);
        }
    }
    if let Some(progress) = progress {
        progress.store(1000, Ordering::Relaxed);
    }
    Ok(())
}

fn unpack(archive: &Path, into: &Path) -> std::io::Result<()> {
    let file = std::fs::File::open(archive)?;
    let decoder = zstd::Decoder::new(file)?;
    tar::Archive::new(decoder).unpack(into)
}
