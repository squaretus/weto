//! Опрос GitHub Releases.
//!
//! Проверка идёт из приложения по HTTP — как на macOS. Разница в том, что
//! перепроверять релиз демону здесь не нужно: ставить будет то же приложение
//! и в свой же домашний каталог.

use serde::Deserialize;

use crate::policy::UpdateInfo;
use crate::version::Version;

#[derive(Debug, thiserror::Error)]
pub enum CheckError {
    #[error("не спросить о релизах: {0}")]
    Request(String),
    #[error("ответ не разбирается: {0}")]
    Parse(String),
    #[error("в релизе {0} нет архива для Linux")]
    NoAsset(String),
}

#[derive(Debug, Deserialize)]
struct Release {
    tag_name: String,
    body: Option<String>,
    #[serde(default)]
    assets: Vec<Asset>,
    #[serde(default)]
    draft: bool,
    #[serde(default)]
    prerelease: bool,
}

#[derive(Debug, Deserialize)]
struct Asset {
    name: String,
    browser_download_url: String,
}

pub struct ReleaseChecker {
    api_url: String,
    /// Суффикс имени архива под текущую машину.
    asset_suffix: String,
}

impl ReleaseChecker {
    pub fn new(repository: &str, arch: &str) -> ReleaseChecker {
        ReleaseChecker {
            api_url: format!("https://api.github.com/repos/{repository}/releases/latest"),
            asset_suffix: format!("-{arch}-linux.tar.zst"),
        }
    }

    /// Только для тестов: подменяет адрес фида локальным сервером.
    ///
    /// Тот же приём, что на macOS, где тесты подставляют свою реализацию
    /// `ReleaseFetching`. У приложения этого пути нет — оно всегда ходит
    /// в GitHub по адресу из `new`.
    pub fn with_api_url(mut self, url: String) -> ReleaseChecker {
        self.api_url = url;
        self
    }

    /// Находит последний релиз и говорит, новее ли он текущей версии.
    ///
    /// Релиз без архива под нашу платформу — не находка, а ошибка: обновляться
    /// на него нечем, и делать вид, что обновление есть, значит показать окно,
    /// которое ничего не установит.
    pub fn latest(&self, current: &Version) -> Result<UpdateInfo, CheckError> {
        let response = ureq::get(&self.api_url)
            .set("Accept", "application/vnd.github+json")
            .set("User-Agent", "weto")
            .call()
            .map_err(|e| CheckError::Request(e.to_string()))?;

        let body = response
            .into_string()
            .map_err(|e| CheckError::Request(e.to_string()))?;
        let release: Release =
            serde_json::from_str(&body).map_err(|e| CheckError::Parse(e.to_string()))?;

        if release.draft || release.prerelease {
            return Err(CheckError::NoAsset(release.tag_name));
        }

        let latest = Version::parse(&release.tag_name)
            .ok_or_else(|| CheckError::Parse(format!("тег «{}» не версия", release.tag_name)))?;

        let asset = release
            .assets
            .iter()
            .find(|asset| asset.name.ends_with(&self.asset_suffix))
            .ok_or_else(|| CheckError::NoAsset(release.tag_name.clone()))?;

        Ok(UpdateInfo {
            latest_version: latest.to_string(),
            download_url: asset.browser_download_url.clone(),
            release_notes: release.body.clone(),
            is_newer: latest > *current,
        })
    }
}
