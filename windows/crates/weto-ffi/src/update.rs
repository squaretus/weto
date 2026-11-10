//! Обновление Windows-версии: установщик и модель экрана для C#.
//!
//! Механизм — общий с Linux (`weto_update::updates::Updates`): проверка
//! по расписанию, отсрочки, пропуск версии, автоустановка. Своё здесь только
//! то, чем ставится найденное, — установщик Inno Setup из того же релиза
//! (`weto-{версия}-{arch}-windows-setup.exe`), — и модель баннера, окна
//! и плитки подвала: тексты и правила показа приходят из `weto_update`,
//! C# их только рисует.

use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use weto_update::dialog::{release_page, UpdateDialogModel};
use weto_update::installer::{download, is_trusted_url};
use weto_update::policy::RemindInterval;
use weto_update::progress::{UpdatePhase, UpdateProgress};
use weto_update::strings::UpdateStrings;
use weto_update::updates::{footer_hint, footer_shows_update, Progress, UpdateInstalling, Updates};
use weto_update::version::Version;

/// Репозиторий релизов — тот же, что у macOS и Linux.
pub const REPOSITORY: &str = "squaretus/weto";

/// Страница релизов — ручной путь, когда своей страницы у находки нет.
pub const RELEASES_URL: &str = "https://github.com/squaretus/weto/releases";

/// Имя приложения в текстах обновления.
pub const APP_NAME: &str = "Weto";

/// Ключи тихой установки Inno Setup: без окон и вопросов, без перезагрузки;
/// `/CLOSEAPPLICATIONS` — страховка, если Weto не успел выйти сам.
pub const SILENT_ARGUMENTS: [&str; 4] = [
    "/VERYSILENT",
    "/SUPPRESSMSGBOXES",
    "/NORESTART",
    "/CLOSEAPPLICATIONS",
];

/// Версия приходит из окружения сборки (`windows/scripts/build.sh`), как у Linux.
pub fn current_version() -> Version {
    option_env!("WETO_VERSION")
        .and_then(Version::parse)
        .unwrap_or(Version {
            major: 0,
            minor: 0,
            patch: 0,
        })
}

/// Конец имени установщика под архитектуру: `x86_64` или `aarch64`,
/// как у архивов Linux.
pub fn asset_suffix(arch: &str) -> String {
    format!("-{arch}-windows-setup.exe")
}

/// Запуск скачанного установщика — граница системы, подменяется в тестах.
pub type Launch = Box<dyn Fn(&std::path::Path) -> std::io::Result<()> + Send + Sync>;

/// Установщик найденной версии: скачать `setup.exe` и запустить его тихо.
///
/// «Установлено» здесь значит «установщик запущен»: заменить файлы
/// работающего приложения он может только после его выхода. Приложение,
/// увидев `Progress::Installed`, выходит штатно (стоящие цели продолжаются),
/// установщик дожидается освобождения мьютекса экземпляра, ставит новую
/// версию и поднимает её сам.
pub struct SetupInstaller {
    cache_dir: PathBuf,
    suffix: String,
    progress: Arc<AtomicU64>,
    launch: Launch,
}

impl SetupInstaller {
    pub fn new(cache_dir: PathBuf, arch: &str) -> SetupInstaller {
        SetupInstaller::with_launch(cache_dir, arch, Box::new(launch_silently))
    }

    pub fn with_launch(cache_dir: PathBuf, arch: &str, launch: Launch) -> SetupInstaller {
        SetupInstaller {
            cache_dir,
            suffix: asset_suffix(arch),
            progress: Arc::new(AtomicU64::new(0)),
            launch,
        }
    }
}

impl UpdateInstalling for SetupInstaller {
    fn install(&self, version: &Version, url: &str) -> Result<(), String> {
        // Адрес пришёл из сети: только https, хосты доставки GitHub и свой
        // установщик — до всякого запроса, как у архива Linux.
        if !is_trusted_url(url, &self.suffix) {
            return Err(format!("недоверенный источник: {url}"));
        }
        std::fs::create_dir_all(&self.cache_dir)
            .map_err(|e| format!("скачивание не удалось: {e}"))?;
        let setup = self.cache_dir.join(format!("weto-{version}-setup.exe"));
        self.progress.store(0, Ordering::Relaxed);
        if let Err(error) = download(url, &setup, Some(&self.progress)) {
            let _ = std::fs::remove_file(&setup);
            return Err(format!("скачивание не удалось: {error}"));
        }
        // Файл остаётся в кэше: установщик ещё работает с него, когда
        // приложения уже нет. Следующая загрузка перезапишет его.
        (self.launch)(&setup).map_err(|e| format!("установщик не запустился: {e}"))
    }

    fn progress(&self) -> f32 {
        self.progress.load(Ordering::Relaxed) as f32 / 1000.0
    }
}

fn launch_silently(setup: &std::path::Path) -> std::io::Result<()> {
    let mut command = std::process::Command::new(setup);
    command.args(SILENT_ARGUMENTS);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // Установщик переживает приложение: своя группа, без консоли.
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
        command.creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP);
    }
    command.spawn().map(|_| ())
}

/// Пункт «Напомнить позже» в команде.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Remind {
    OneHour,
    ThreeHours,
    SixHours,
}

impl From<Remind> for RemindInterval {
    fn from(remind: Remind) -> RemindInterval {
        match remind {
            Remind::OneHour => RemindInterval::OneHour,
            Remind::ThreeHours => RemindInterval::ThreeHours,
            Remind::SixHours => RemindInterval::SixHours,
        }
    }
}

impl From<RemindInterval> for Remind {
    fn from(interval: RemindInterval) -> Remind {
        match interval {
            RemindInterval::OneHour => Remind::OneHour,
            RemindInterval::ThreeHours => Remind::ThreeHours,
            RemindInterval::SixHours => Remind::SixHours,
        }
    }
}

/// Всё, что интерфейс показывает об обновлении, одним видом.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateView {
    /// Баннер в попапе; `None` — сказать нечего.
    pub banner: Option<BannerView>,
    /// Окно обновления; `None` — находки нет, открытое окно закрывается.
    pub dialog: Option<UpdateDialogView>,
    /// Находка просит окно — открыть один раз (просьба забирается чтением).
    pub window_requested: bool,
    pub auto_install: bool,
    pub footer: FooterView,
    /// Установщик запущен: приложению пора выйти штатно.
    pub installed: bool,
    pub labels: UpdateLabels,
}

/// Порт ветки баннера `StatusPopupView`: текст фазы, тон Warning при отказе,
/// индикатор вместо «Подробнее», пока идёт работа.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BannerView {
    pub text: String,
    pub warning: bool,
    pub in_flight: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateDialogView {
    pub title: String,
    pub detail: String,
    pub fraction: Option<f64>,
    pub shows_progress: bool,
    pub shows_choice_buttons: bool,
    pub shows_release_page_button: bool,
    /// Проверенная страница релиза (https на github.com) или `None`.
    pub release_page: Option<String>,
}

/// Плитка «Проверить обновления» в подвале настроек — как `SettingsFooter`.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FooterView {
    /// Находка известна: нажатие покажет её, а не начнёт проверку.
    pub offers: bool,
    pub hint: String,
    /// Идут проверка или установка: плитка неактивна.
    pub busy: bool,
    /// Имя для диктора.
    pub label: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateLabels {
    pub window_title: String,
    pub details: String,
    pub skip: String,
    pub remind_later: String,
    pub install: String,
    pub open_release_page: String,
    pub auto_install: String,
    pub remind: Vec<RemindOption>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RemindOption {
    pub interval: Remind,
    pub title: String,
}

pub fn update_view(updates: &Updates, window_requested: bool) -> UpdateView {
    let strings = UpdateStrings::new(APP_NAME);
    let pending = updates.pending();
    let progress = updates.update_progress();
    let state = updates.state();
    let offers = footer_shows_update(&state, pending.is_some());
    UpdateView {
        banner: pending
            .as_ref()
            .map(|info| banner(&strings, &progress, &info.latest_version)),
        dialog: pending.as_ref().map(|info| {
            let model = UpdateDialogModel::make(Some(info), &progress, &strings);
            UpdateDialogView {
                title: model.title,
                detail: model.detail,
                fraction: model.fraction,
                shows_progress: model.shows_progress,
                shows_choice_buttons: model.shows_choice_buttons,
                shows_release_page_button: model.shows_release_page_button,
                release_page: release_page(Some(info), RELEASES_URL),
            }
        }),
        window_requested,
        auto_install: updates.auto_install(),
        footer: FooterView {
            offers,
            hint: footer_hint(&state, progress.is_in_flight()),
            busy: updates.is_busy(),
            label: if offers {
                "Показать обновление"
            } else {
                "Проверить обновления"
            }
            .to_string(),
        },
        installed: updates.progress() == Progress::Installed,
        labels: UpdateLabels {
            window_title: strings.progress_title(),
            details: "Подробнее".to_string(),
            skip: strings.skip().to_string(),
            remind_later: strings.remind_later().to_string(),
            install: strings.install().to_string(),
            open_release_page: strings.open_release_page().to_string(),
            auto_install: strings.auto_install_toggle().to_string(),
            remind: RemindInterval::ALL
                .iter()
                .map(|interval| RemindOption {
                    interval: Remind::from(*interval),
                    title: strings.remind_title(*interval).to_string(),
                })
                .collect(),
        },
    }
}

fn banner(strings: &UpdateStrings, progress: &UpdateProgress, version: &str) -> BannerView {
    BannerView {
        text: strings.banner_progress(progress, version),
        warning: progress.phase == UpdatePhase::Failed,
        in_flight: progress.is_in_flight(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::sync::Mutex;
    use std::time::Duration;

    use weto_update::checker::CheckError;
    use weto_update::policy::UpdateInfo;
    use weto_update::scheduler::{CheckState, Examination, Finding, ReleaseLooking};

    struct Latest(&'static str);

    impl ReleaseLooking for Latest {
        fn latest(&self, current: &Version) -> Result<UpdateInfo, CheckError> {
            Ok(info(self.0, current))
        }
    }

    fn info(latest: &str, current: &Version) -> UpdateInfo {
        UpdateInfo {
            current_version: current.to_string(),
            latest_version: latest.to_string(),
            release_url: format!("https://github.com/squaretus/weto/releases/tag/v{latest}"),
            download_url: format!(
                "https://github.com/squaretus/weto/releases/download/v{latest}/weto-{latest}-x86_64-windows-setup.exe"
            ),
            is_newer: true,
        }
    }

    fn updates(installer: Arc<dyn UpdateInstalling>) -> (Arc<Updates>, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let updates = Updates::new(
            dir.path().to_path_buf(),
            installer,
            Arc::new(Latest("1.2.0")),
            Version::parse("1.1.0").unwrap(),
        );
        (updates, dir)
    }

    fn found(updates: &Arc<Updates>) {
        let info = info("1.2.0", &Version::parse("1.1.0").unwrap());
        updates.apply(Examination {
            state: CheckState::Available(info.clone()),
            finding: Some(Finding::Prompt(info)),
        });
    }

    fn wait_until(what: &str, done: impl Fn() -> bool) {
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while !done() {
            assert!(std::time::Instant::now() < deadline, "не дождались: {what}");
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    /// Чужой хост и чужой файл отвергаются до всякого запроса и запуска.
    #[test]
    fn only_our_setup_from_github_is_installed() {
        let launched = Arc::new(Mutex::new(Vec::new()));
        let seen = launched.clone();
        let dir = tempfile::tempdir().unwrap();
        let installer = SetupInstaller::with_launch(
            dir.path().to_path_buf(),
            "x86_64",
            Box::new(move |path| {
                seen.lock().unwrap().push(path.to_path_buf());
                Ok(())
            }),
        );
        let version = Version::parse("1.2.0").unwrap();

        for url in [
            "https://evil.example/weto-1.2.0-x86_64-windows-setup.exe",
            "http://github.com/x/weto-1.2.0-x86_64-windows-setup.exe",
            "https://github.com@evil.example/weto-1.2.0-x86_64-windows-setup.exe",
            "https://github.com/x/weto-1.2.0-aarch64-windows-setup.exe",
            "https://github.com/x/weto-1.2.0-x86_64-linux.tar.zst",
        ] {
            let error = installer.install(&version, url).unwrap_err();
            assert!(error.starts_with("недоверенный источник"), "{url}: {error}");
        }
        assert!(launched.lock().unwrap().is_empty(), "запущено чужое");
    }

    #[test]
    fn the_asset_is_named_like_the_release_build() {
        assert_eq!(asset_suffix("aarch64"), "-aarch64-windows-setup.exe");
    }

    /// Находка: баннер «доступно», окно с выбором, плитка показывает находку.
    #[test]
    fn a_finding_shows_the_banner_the_choice_and_the_footer_offer() {
        let (updates, _dir) = updates(Arc::new(Refusing));
        found(&updates);

        let view = update_view(&updates, updates.take_window_request().is_some());

        assert!(view.window_requested);
        let banner = view.banner.expect("баннера нет");
        assert!(!banner.in_flight && !banner.warning);
        assert!(banner.text.contains("1.2.0"), "{}", banner.text);
        let dialog = view.dialog.expect("окна нет");
        assert!(dialog.shows_choice_buttons && !dialog.shows_progress);
        assert_eq!(
            dialog.release_page.as_deref(),
            Some("https://github.com/squaretus/weto/releases/tag/v1.2.0")
        );
        assert!(view.footer.offers);
        assert_eq!(view.footer.label, "Показать обновление");
        assert!(!view.installed);
        assert_eq!(view.labels.remind.len(), 3);
    }

    /// Отказ установщика: баннер предупреждает, окно оставляет ручной путь.
    #[test]
    fn a_failed_install_warns_and_leaves_the_release_page() {
        let (updates, _dir) = updates(Arc::new(Refusing));
        found(&updates);
        updates.install(&updates.pending().unwrap());
        wait_until("отказ установщика", || {
            matches!(updates.progress(), Progress::Failed(_))
        });

        let view = update_view(&updates, false);

        assert!(view.banner.unwrap().warning);
        let dialog = view.dialog.unwrap();
        assert!(dialog.shows_release_page_button && !dialog.shows_choice_buttons);
        assert!(!view.installed);
    }

    /// Запущенный установщик — сигнал приложению выйти.
    #[test]
    fn a_launched_setup_tells_the_app_to_quit() {
        let (updates, _dir) = updates(Arc::new(Launching));
        found(&updates);
        updates.install(&updates.pending().unwrap());
        wait_until("запуск установщика", || {
            updates.progress() == Progress::Installed
        });

        assert!(update_view(&updates, false).installed);
    }

    /// Пропуск убирает находку: ни баннера, ни окна.
    #[test]
    fn skipping_hides_the_banner_and_closes_the_window() {
        let (updates, _dir) = updates(Arc::new(Refusing));
        found(&updates);

        updates.skip("1.2.0");
        let view = update_view(&updates, false);

        assert_eq!(view.banner, None);
        assert_eq!(view.dialog, None);
    }

    struct Refusing;

    impl UpdateInstalling for Refusing {
        fn install(&self, _: &Version, url: &str) -> Result<(), String> {
            Err(format!("недоверенный источник: {url}"))
        }
        fn progress(&self) -> f32 {
            0.0
        }
    }

    struct Launching;

    impl UpdateInstalling for Launching {
        fn install(&self, _: &Version, _: &str) -> Result<(), String> {
            Ok(())
        }
        fn progress(&self) -> f32 {
            1.0
        }
    }
}
