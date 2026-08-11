//! Скачивание, проверка и установка обновления.
//!
//! Порядок фиксирован и менять его нельзя: скачать → проверить подпись →
//! распаковать рядом → переставить симлинк. Проверка стоит до распаковки,
//! потому что распаковывать чужое уже поздно.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use crate::layout::{staging_dir, Layout};
use crate::signature::{self, release_public_key};
use crate::version::Version;

/// Фаза установки. Незнакомый код на macOS читается как «идёт установка»,
/// а не как «простой»; здесь фаза своя и типизирована, но правило то же:
/// молчание не выдаётся за успех.
#[derive(Debug, Clone, PartialEq)]
pub enum Phase {
    Idle,
    Downloading { fraction: f32 },
    Verifying,
    Unpacking,
    Restarting,
    Failed(String),
}

#[derive(Debug, thiserror::Error)]
pub enum InstallError {
    #[error("сборка без ключа подписи обновляться не может")]
    NoReleaseKey,
    #[error("недоверенный источник: {0}")]
    UntrustedHost(String),
    #[error("скачивание не удалось: {0}")]
    Download(String),
    #[error("подпись не сошлась: {0}")]
    Signature(String),
    #[error("распаковка не удалась: {0}")]
    Unpack(String),
    #[error("не переключить версию: {0}")]
    Activate(String),
}

/// Скачиваем только с GitHub: адрес приходит из ответа API, и подставить туда
/// чужой хост — первое, что сделает подменивший ответ.
pub fn is_trusted_host(url: &str) -> bool {
    const TRUSTED: [&str; 2] = [
        "https://github.com/",
        "https://objects.githubusercontent.com/",
    ];
    TRUSTED.iter().any(|prefix| url.starts_with(prefix))
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

    pub fn install(
        &self,
        version: &Version,
        archive_url: &str,
        signature_url: &str,
    ) -> Result<(), InstallError> {
        let Some(public_key) = release_public_key() else {
            return Err(InstallError::NoReleaseKey);
        };
        for url in [archive_url, signature_url] {
            if !is_trusted_host(url) {
                return Err(InstallError::UntrustedHost(url.to_string()));
            }
        }

        // Каталог загрузки закрыт от чужих глаз: между скачиванием и проверкой
        // подписи файл не должен быть доступен на запись никому, кроме нас.
        std::fs::create_dir_all(&self.cache_dir)
            .map_err(|e| InstallError::Download(e.to_string()))?;
        harden(&self.cache_dir);

        let archive = self.cache_dir.join(format!("weto-{version}.tar.zst"));
        let signature = self
            .cache_dir
            .join(format!("weto-{version}.tar.zst.minisig"));

        let result = self.run(
            version,
            archive_url,
            signature_url,
            &archive,
            &signature,
            public_key,
        );

        // Скачанное не остаётся на диске ни при успехе, ни при провале.
        let _ = std::fs::remove_file(&archive);
        let _ = std::fs::remove_file(&signature);
        result
    }

    fn run(
        &self,
        version: &Version,
        archive_url: &str,
        signature_url: &str,
        archive: &Path,
        signature: &Path,
        public_key: &str,
    ) -> Result<(), InstallError> {
        self.progress.store(0, Ordering::Relaxed);
        download(archive_url, archive, Some(&self.progress))
            .map_err(|e| InstallError::Download(e.to_string()))?;
        download(signature_url, signature, None)
            .map_err(|e| InstallError::Download(e.to_string()))?;

        signature::verify(archive, signature, public_key)
            .map_err(|e| InstallError::Signature(e.to_string()))?;

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
