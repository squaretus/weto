//! Обновление терминальной версии: `weto update check | install` и суточная
//! проверка в работающей охране.
//!
//! Источник тот же, что у приложения с окном, — последний релиз
//! `squaretus/weto` на GitHub, — но ассет свой: `weto-cli-<версия>-linux-<arch>.tar.gz`
//! с одним файлом `weto`. Сверка версий и список хостов доставки — общие
//! с обновлятором приложения (`weto-update`): расходиться им не положено.
//!
//! Защита — та же пара, что у приложения (https и только хосты доставки
//! GitHub), плюс контрольная сумма из `SHA256SUMS` того же релиза. Сумма
//! не совпала, её нет или нет ассета — отказ, и текущий бинарник не тронут:
//! заменяется он одним `rename`, а до него всё происходит рядом.

use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use serde::Deserialize;
use sha2::{Digest, Sha256};
use weto_update::installer::is_trusted_url;
use weto_update::version::Version;

/// Последний релиз. Черновики и пререлизы GitHub сюда не отдаёт.
pub const LATEST_RELEASE_URL: &str = "https://api.github.com/repos/squaretus/weto/releases/latest";

/// Имя файла сумм в релизе — как его печатает `sha256sum`.
pub const SUMS_ASSET: &str = "SHA256SUMS";

/// Имя бинарника внутри архива и в поставке.
pub const BINARY_NAME: &str = "weto";

/// Через сколько после старта охрана впервые спрашивает о релизах и как часто
/// потом. Сервер живёт месяцами без перезапуска — без расписания он не узнал
/// бы о новой версии никогда.
pub const FIRST_CHECK_DELAY: Duration = Duration::from_secs(60);
pub const CHECK_INTERVAL: Duration = Duration::from_secs(24 * 3600);

/// Ответ на запрос — граница системы, в тестах подменяется.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FetchError {
    /// 404 на `releases/latest`: у репозитория ещё нет ни одного релиза.
    NotFound,
    Failed(String),
}

impl std::fmt::Display for FetchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FetchError::NotFound => write!(f, "релизов пока нет"),
            FetchError::Failed(text) => write!(f, "{text}"),
        }
    }
}

/// Сеть для обновления: тело ответа на GET целиком.
pub trait ReleaseFetching: Send + Sync {
    fn fetch(&self, url: &str) -> Result<Vec<u8>, FetchError>;
}

/// Сколько ждать ответа целиком. Бинарник — мегабайты, а сервер, принявший
/// соединение и замолчавший, иначе держал бы команду вечно.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);
const READ_TIMEOUT: Duration = Duration::from_secs(60);
/// Потолок тела: ответ больше — не наш релиз, а поток мусора.
const BODY_LIMIT: u64 = 256 * 1024 * 1024;

pub struct HttpReleases {
    agent: ureq::Agent,
}

impl HttpReleases {
    pub fn new() -> HttpReleases {
        HttpReleases {
            agent: ureq::AgentBuilder::new()
                .timeout_connect(CONNECT_TIMEOUT)
                .timeout_read(READ_TIMEOUT)
                .build(),
        }
    }
}

impl Default for HttpReleases {
    fn default() -> Self {
        HttpReleases::new()
    }
}

impl ReleaseFetching for HttpReleases {
    fn fetch(&self, url: &str) -> Result<Vec<u8>, FetchError> {
        let mut request = self.agent.get(url).set("User-Agent", "weto");
        if url.starts_with("https://api.github.com/") {
            request = request.set("Accept", "application/vnd.github+json");
        }
        let response = request.call().map_err(|error| match error {
            ureq::Error::Status(404, _) => FetchError::NotFound,
            other => FetchError::Failed(other.to_string()),
        })?;
        let mut body = Vec::new();
        response
            .into_reader()
            .take(BODY_LIMIT)
            .read_to_end(&mut body)
            .map_err(|error| FetchError::Failed(error.to_string()))?;
        Ok(body)
    }
}

/// Каталог и файл бинарника — граница: тесту незачем заменять самого себя,
/// а отказ в правах под root в контейнере не воспроизвести.
pub trait BinaryFiles: Send + Sync {
    /// Можно ли писать в каталог — по эффективному uid, как решит ядро.
    fn writable(&self, directory: &Path) -> bool;
    /// Записать новый бинарник рядом и переименовать поверх старого.
    fn replace(&self, executable: &Path, contents: &[u8]) -> io::Result<()>;
}

pub struct DiskBinary;

impl BinaryFiles for DiskBinary {
    fn writable(&self, directory: &Path) -> bool {
        use std::os::unix::ffi::OsStrExt;
        let Ok(path) = std::ffi::CString::new(directory.as_os_str().as_bytes()) else {
            return false;
        };
        // SAFETY: faccessat только спрашивает ядро о правах на путь.
        unsafe { libc::faccessat(libc::AT_FDCWD, path.as_ptr(), libc::W_OK, libc::AT_EACCESS) == 0 }
    }

    fn replace(&self, executable: &Path, contents: &[u8]) -> io::Result<()> {
        replace_file(executable, contents)
    }
}

/// Замена бинарника: `.weto.new` рядом (`0755`), запись до диска и `rename`
/// поверх. Работающий процесс держит старый inode и доживает на нём, а
/// следующий запуск — уже новый файл. Половины файла не увидит никто:
/// `rename` в пределах каталога атомарен.
pub fn replace_file(executable: &Path, contents: &[u8]) -> io::Result<()> {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    let directory = executable
        .parent()
        .ok_or_else(|| io::Error::other("у бинарника нет каталога"))?;
    let staged = directory.join(".weto.new");
    let _ = std::fs::remove_file(&staged);
    let result = (|| {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o755)
            .open(&staged)?;
        file.write_all(contents)?;
        file.sync_all()?;
        // Режим при создании режет umask — задаём его явно.
        std::fs::set_permissions(&staged, std::fs::Permissions::from_mode(0o755))?;
        std::fs::rename(&staged, executable)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&staged);
    }
    result
}

// --- релиз -------------------------------------------------------------------

#[derive(Debug, Deserialize)]
struct ReleaseJson {
    tag_name: String,
    #[serde(default)]
    assets: Vec<AssetJson>,
}

#[derive(Debug, Clone, Deserialize)]
struct AssetJson {
    name: String,
    browser_download_url: String,
}

/// Последний релиз: версия и ассеты по имени.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Release {
    pub version: Version,
    pub assets: Vec<(String, String)>,
}

impl Release {
    pub fn asset(&self, name: &str) -> Option<&str> {
        self.assets
            .iter()
            .find(|(asset, _)| asset == name)
            .map(|(_, url)| url.as_str())
    }
}

pub fn parse_release(body: &[u8]) -> Result<Release, String> {
    let json: ReleaseJson =
        serde_json::from_slice(body).map_err(|error| format!("ответ не разбирается: {error}"))?;
    let version = Version::parse(&json.tag_name)
        .ok_or_else(|| format!("тег «{}» не версия", json.tag_name))?;
    Ok(Release {
        version,
        assets: json
            .assets
            .into_iter()
            .map(|asset| (asset.name, asset.browser_download_url))
            .collect(),
    })
}

/// Архив терминальной версии под эту машину. Архитектура — та же строка,
/// что печатает `uname -m` (`x86_64`, `aarch64`): по ней архив и назван.
pub fn asset_name(version: &Version) -> String {
    format!("weto-cli-{version}-linux-{}.tar.gz", std::env::consts::ARCH)
}

/// Своя версия, если её есть с чем сравнивать. `dev` (и `0.0.0` прежних
/// сборок) — сборка без версии (`cargo build` без `WETO_VERSION`).
pub fn known_version(text: &str) -> Option<Version> {
    Version::parse(text).filter(|version| *version != Version::parse("0.0.0").expect("версия"))
}

/// Сумма файла из `SHA256SUMS`: строки `<hex>  <имя>`, в двоичном режиме —
/// `<hex> *<имя>`. Имя сверяется целиком.
pub fn checksum_for(sums: &str, name: &str) -> Option<String> {
    sums.lines().find_map(|line| {
        let (hash, file) = line.trim().split_once(char::is_whitespace)?;
        let file = file.trim_start().trim_start_matches('*');
        (file == name && hash.len() == 64 && hash.chars().all(|c| c.is_ascii_hexdigit()))
            .then(|| hash.to_ascii_lowercase())
    })
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

/// Бинарник `weto` из архива. Внутри обязан быть ровно один файл `weto`
/// (`./weto` — тоже он): архив собирает `tar -C … weto`, и всё лишнее в нём —
/// признак не того архива. Ошибка — деталь для «архив … не годится: …».
pub fn extract_binary(archive: &[u8]) -> Result<Vec<u8>, String> {
    let unreadable = |_| "tar не прочитал архив".to_string();
    let decoder = flate2::read::GzDecoder::new(archive);
    let mut tar = tar::Archive::new(decoder);
    let mut names = Vec::new();
    let mut binary = None;
    for entry in tar.entries().map_err(unreadable)? {
        let mut entry = entry.map_err(unreadable)?;
        let path = entry.path().map_err(unreadable)?.into_owned();
        let name = path
            .strip_prefix(".")
            .unwrap_or(&path)
            .to_string_lossy()
            .into_owned();
        if name.is_empty() {
            continue; // `./` — сам каталог архива
        }
        if name == BINARY_NAME && entry.header().entry_type().is_file() {
            let mut contents = Vec::new();
            entry
                .read_to_end(&mut contents)
                .map_err(|error| error.to_string())?;
            binary = Some(contents);
        }
        names.push(name);
    }
    match binary {
        Some(contents) if names.len() == 1 => {
            if contents.is_empty() {
                Err(format!("файл {BINARY_NAME} пустой"))
            } else {
                Ok(contents)
            }
        }
        _ => Err(format!(
            "внутри должен быть ровно один файл {BINARY_NAME}, а там: {}",
            if names.is_empty() {
                "ничего".to_string()
            } else {
                names.join(", ")
            }
        )),
    }
}

// --- проверка и установка ------------------------------------------------------

/// Чем кончилась проверка.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Check {
    Newer {
        current: Version,
        latest: Release,
    },
    /// Релиз новее, но терминальной версии для этой системы в нём нет —
    /// последний релиз бывает только приложением. Обновляться не на что,
    /// и «доступным» такой релиз не считается.
    WithoutOurAsset(Version),
    UpToDate(Version),
}

pub fn check(fetcher: &dyn ReleaseFetching, current: Version) -> Result<Check, String> {
    let body = fetcher
        .fetch(LATEST_RELEASE_URL)
        .map_err(|error| error.to_string())?;
    let latest = parse_release(&body)?;
    Ok(if latest.version <= current {
        Check::UpToDate(current)
    } else if latest.asset(&asset_name(&latest.version)).is_none() {
        Check::WithoutOurAsset(latest.version)
    } else {
        Check::Newer { current, latest }
    })
}

/// «не удалось проверить обновления: …» — у команды и в логе охраны.
pub fn check_failed_text(detail: &str) -> String {
    format!("не удалось проверить обновления: {detail}")
}

/// Ответ `update check` на релиз без своего архива.
pub fn without_asset_text(version: &Version) -> String {
    format!("в последнем релизе {version} нет терминальной версии для этой системы")
}

/// Скачать и проверить новый бинарник. Ничего не пишет на диск: замена —
/// забота того, кто зовёт, и только после того, как здесь всё сошлось.
pub fn download_verified(
    fetcher: &dyn ReleaseFetching,
    release: &Release,
) -> Result<Vec<u8>, String> {
    let name = asset_name(&release.version);
    let refused = |reason: String| format!("{reason} — ничего не заменено");
    let version = release.version;

    let archive_url = release
        .asset(&name)
        .ok_or_else(|| refused(format!("в релизе {version} нет файла {name}")))?;
    let sums_url = release.asset(SUMS_ASSET).ok_or_else(|| {
        format!("в релизе {version} нет {SUMS_ASSET} — без контрольной суммы ничего не заменено")
    })?;
    for (url, file) in [(archive_url, name.as_str()), (sums_url, SUMS_ASSET)] {
        if !is_trusted_url(url, file) {
            return Err(refused(format!("ссылка на {file} ведёт не на GitHub")));
        }
    }

    let download = |url: &str, file: &str| {
        fetcher
            .fetch(url)
            .map_err(|error| refused(format!("не удалось скачать {file}: {error}")))
    };
    let sums = download(sums_url, SUMS_ASSET)?;
    let expected = checksum_for(&String::from_utf8_lossy(&sums), &name)
        .ok_or_else(|| refused(format!("в {SUMS_ASSET} нет суммы для {name}")))?;
    let archive = download(archive_url, &name)?;
    if sha256_hex(&archive) != expected {
        return Err(refused(format!(
            "контрольная сумма {name} не совпала с {SUMS_ASSET}"
        )));
    }
    extract_binary(&archive).map_err(|detail| refused(format!("архив {name} не годится: {detail}")))
}

/// Куда ставить: путь текущего исполняемого файла после разворота симлинков —
/// симлинк `/usr/local/bin/weto` остаётся ссылкой, заменяется то, на что он ведёт.
pub fn install_target(executable: &Path) -> io::Result<PathBuf> {
    executable.canonicalize()
}

// --- суточная проверка в работающей охране -----------------------------------

/// Расписание и память суточной проверки. Чистое: время и ответ приходят
/// снаружи, наружу уходят строка лога и найденная версия.
///
/// Новая версия называется в логе один раз — сервер живёт месяцами, и строка
/// каждые сутки о той же версии лог бы засоряла. Отказ сети — одна строка
/// на серию отказов подряд, но не чаще раза в сутки. Релиз без терминальной
/// версии для этой системы доступным не считается и в лог не попадает.
#[derive(Debug, Default)]
pub struct UpdateWatch {
    announced: Option<Version>,
    available: Option<Version>,
    failure_logged_at: Option<SystemTime>,
}

impl UpdateWatch {
    pub fn new() -> UpdateWatch {
        UpdateWatch::default()
    }

    /// Найденная новая версия — для `updateAvailable` в статусе.
    pub fn available(&self) -> Option<String> {
        self.available.map(|version| version.to_string())
    }

    /// Учесть ответ проверки. Возвращает строку для лога, если сказать есть что.
    pub fn record(&mut self, result: Result<Check, String>, now: SystemTime) -> Option<String> {
        match result {
            Ok(Check::Newer { latest, .. }) => {
                self.failure_logged_at = None;
                self.available = Some(latest.version);
                if self.announced == Some(latest.version) {
                    return None;
                }
                self.announced = Some(latest.version);
                Some(available_text(&latest.version))
            }
            Ok(Check::WithoutOurAsset(_) | Check::UpToDate(_)) => {
                self.failure_logged_at = None;
                self.available = None;
                None
            }
            Err(error) => {
                let quiet = self.failure_logged_at.is_some_and(|at| {
                    now.duration_since(at).unwrap_or(Duration::ZERO) < CHECK_INTERVAL
                });
                if quiet {
                    return None;
                }
                self.failure_logged_at = Some(now);
                Some(check_failed_text(&error))
            }
        }
    }
}

/// «доступна версия 0.3.0: sudo weto update» — строка лога работающей охраны.
pub fn available_text(version: &Version) -> String {
    format!("доступна версия {version}: sudo weto update")
}
