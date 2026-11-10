//! Обновление со стороны приложения — порт `UpdateController` с macOS:
//! проверка, показ, установка. Общее для Linux и Windows: платформа подставляет
//! только установщик (`UpdateInstalling`) — архив в версионный каталог на Linux,
//! `setup.exe` на Windows. Жило в GTK-крейте `weto-app`, перенесено без
//! изменения поведения.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::policy::{RemindInterval, UpdateDeferral, UpdateInfo};
use crate::progress::{UpdatePhase, UpdateProgress};
use crate::scheduler::{
    CheckState, DeferralReading, Examination, Finding, ReleaseLooking, UpdateScheduler,
};
use crate::store::UpdateStore;
use crate::version::Version;

/// Установщик найденной версии. Блокирующий: зовётся с рабочего потока.
/// `progress` — доля загрузки 0…1, её читает отдельный поток.
pub trait UpdateInstalling: Send + Sync {
    fn install(&self, version: &Version, url: &str) -> Result<(), String>;
    fn progress(&self) -> f32;
}

/// Ход установки — то, что видит окно.
#[derive(Debug, Clone, PartialEq)]
pub enum Progress {
    Idle,
    Running(f32),
    Failed(String),
    /// Установка удалась; дальше только перезапуск.
    Installed,
}

impl Progress {
    /// Ход в фазах macOS — ими говорит баннер. Отдельной фазы распаковки
    /// установщик не сообщает, но загрузка кончается долей 1.0 ровно перед ней:
    /// всё, что после полной доли, — уже установка. Успех читается так же:
    /// следом идёт перезапуск, и «Доступно обновление» было бы неправдой.
    pub fn as_update_progress(&self) -> UpdateProgress {
        match self {
            Progress::Idle => UpdateProgress::idle(),
            Progress::Running(fraction) if *fraction < 1.0 => {
                UpdateProgress::new(UpdatePhase::Downloading, f64::from(*fraction), None)
            }
            Progress::Running(_) | Progress::Installed => {
                UpdateProgress::new(UpdatePhase::Installing, 1.0, None)
            }
            Progress::Failed(reason) => {
                UpdateProgress::new(UpdatePhase::Failed, 0.0, Some(reason.clone()))
            }
        }
    }
}

/// Обновление со стороны приложения — порт `UpdateController` с macOS:
/// исход проверки для подвала, находка для баннера и окна, ход установки.
pub struct Updates {
    store: Arc<UpdateStore>,
    installer: Arc<dyn UpdateInstalling>,
    checker: Arc<dyn ReleaseLooking>,
    current: Version,
    progress: Mutex<Progress>,
    /// Найденное обновление, если о нём стоит говорить: баннер и окно.
    pending: Mutex<Option<UpdateInfo>>,
    /// Исход последней проверки — его читает плитка подвала.
    state: Mutex<CheckState>,
    /// Находка просит окно. Проверка идёт на чужом потоке, а окна открывает
    /// только главный цикл: просьбу забирает его такт (`present_requested`).
    window_requested: AtomicBool,
    /// Автоустановка: одна настройка на тумблер «Обслуживания» и галочку окна.
    /// В памяти, а не чтением файла: оба места сверяются с ней каждый такт.
    auto_install: AtomicBool,
}

pub struct StoreDeferrals(pub Arc<UpdateStore>);

impl DeferralReading for StoreDeferrals {
    fn deferral(&self) -> UpdateDeferral {
        self.0.deferral()
    }
}

impl Updates {
    /// `state_dir` — где хранится отсрочка и пропуск версии; установщик —
    /// платформенный (Linux: архив в версионный каталог, Windows: setup.exe).
    pub fn new(
        state_dir: PathBuf,
        installer: Arc<dyn UpdateInstalling>,
        checker: Arc<dyn ReleaseLooking>,
        current: Version,
    ) -> Arc<Updates> {
        let store = Arc::new(UpdateStore::new(state_dir));
        let auto_install = store.deferral().auto_install;
        Arc::new(Updates {
            store,
            installer,
            checker,
            current,
            progress: Mutex::new(Progress::Idle),
            pending: Mutex::new(None),
            state: Mutex::new(CheckState::Idle),
            window_requested: AtomicBool::new(false),
            auto_install: AtomicBool::new(auto_install),
        })
    }

    /// Отсрочка и пропуск для расписания проверок — то же хранилище, что у окна.
    pub fn deferrals(&self) -> Arc<dyn DeferralReading> {
        Arc::new(StoreDeferrals(self.store.clone()))
    }

    pub fn current(&self) -> Version {
        self.current
    }

    pub fn pending(&self) -> Option<UpdateInfo> {
        self.pending.lock().expect("обновление").clone()
    }

    pub fn progress(&self) -> Progress {
        self.progress.lock().expect("обновление").clone()
    }

    pub fn state(&self) -> CheckState {
        self.state.lock().expect("обновление").clone()
    }

    /// Ход в фазах macOS. Ручная проверка — тоже фаза: пока она идёт,
    /// окно и баннер говорят «Проверка релиза…», а плитка неактивна.
    pub fn update_progress(&self) -> UpdateProgress {
        let progress = self.progress();
        if progress == Progress::Idle && self.state() == CheckState::Checking {
            return UpdateProgress::new(UpdatePhase::Checking, 0.0, None);
        }
        progress.as_update_progress()
    }

    /// Идёт проверка или установка: плитке подвала нажимать нечего.
    pub fn is_busy(&self) -> bool {
        self.update_progress().is_in_flight()
    }

    /// Применяет исход проверки — порт `apply` в `UpdateController`.
    ///
    /// Предложение открывает окно само, как на macOS. Прежний отказ
    /// установки при этом забывается: иначе окно навсегда осталось бы
    /// с одной кнопкой страницы релиза, и повторить установку было бы нечем
    /// до перезапуска.
    pub fn apply(self: &Arc<Self>, examination: Examination) {
        *self.state.lock().expect("обновление") = examination.state;
        match examination.finding {
            Some(Finding::Prompt(info)) => {
                {
                    let mut progress = self.progress.lock().expect("обновление");
                    if matches!(*progress, Progress::Failed(_)) {
                        *progress = Progress::Idle;
                    }
                }
                *self.pending.lock().expect("обновление") = Some(info);
                self.window_requested.store(true, Ordering::SeqCst);
            }
            // Автоустановка идёт молча: ни окна, ни баннера.
            Some(Finding::Install(info)) => self.install(&info),
            None => {}
        }
    }

    /// Забирает просьбу показать окно — с тем, что показывать.
    pub fn take_window_request(&self) -> Option<UpdateInfo> {
        if !self.window_requested.swap(false, Ordering::SeqCst) {
            return None;
        }
        self.pending()
    }

    /// Найденная версия, если она есть: плитка подвала открывает по ней окно,
    /// а не проверяет заново. Молчащая версия (пропуск, отсрочка) тоже
    /// считается — нажатие на плитку на macOS возвращает и её.
    pub fn found(&self) -> Option<UpdateInfo> {
        if let Some(info) = self.pending() {
            return Some(info);
        }
        let CheckState::Available(info) = self.state() else {
            return None;
        };
        *self.pending.lock().expect("обновление") = Some(info.clone());
        Some(info)
    }

    /// Ручная проверка игнорирует пропуск и отсрочку. Вторая, пока идёт
    /// первая, не начинается.
    pub fn check_now(self: &Arc<Self>) {
        {
            let mut state = self.state.lock().expect("обновление");
            if *state == CheckState::Checking {
                return;
            }
            *state = CheckState::Checking;
        }

        let updates = self.clone();
        std::thread::spawn(move || {
            let examination = UpdateScheduler::new(
                updates.current,
                updates.checker.clone(),
                Arc::new(StoreDeferrals(updates.store.clone())),
            )
            .examine(true);
            updates.apply(examination);
        });
    }

    /// «Напомнить позже»: окно не всплывает до срока. Дата абсолютная
    /// и переживает перезапуск.
    pub fn remind_later(&self, interval: RemindInterval) {
        self.store.remind_later(interval.duration());
        *self.pending.lock().expect("обновление") = None;
    }

    /// Окно закрыли крестиком: молчаливое закрытие не значит «больше никогда».
    pub fn dismiss(&self) {
        self.remind_later(RemindInterval::ON_CLOSE);
    }

    /// «Пропустить версию»: действует до выхода версии выше и снимается сам.
    pub fn skip(&self, version: &str) {
        self.store.skip(version);
        *self.pending.lock().expect("обновление") = None;
    }

    pub fn auto_install(&self) -> bool {
        self.auto_install.load(Ordering::SeqCst)
    }

    /// Автоустановка — как сеттер `isAutoInstallEnabled` на macOS: пишет
    /// в то же хранилище и сразу ставит найденное обновление, иначе
    /// включённая настройка не делала бы того, ради чего её включают.
    ///
    /// Повтор того же значения — ничто: тумблер и галочка сверяются с этим
    /// значением каждый такт, и сверка не должна оборачиваться действием.
    pub fn set_auto_install(self: &Arc<Self>, enabled: bool) {
        if self.auto_install.swap(enabled, Ordering::SeqCst) == enabled {
            return;
        }
        self.store.set_auto_install(enabled);
        if !enabled {
            return;
        }
        if let CheckState::Available(info) = self.state() {
            self.install(&info);
        }
    }

    /// Установка на рабочем потоке. Окно читает ход через `progress`.
    /// Вторая, пока идёт первая, не начинается.
    pub fn install(self: &Arc<Self>, info: &UpdateInfo) {
        if self.progress().as_update_progress().is_in_flight() {
            return;
        }
        let Some(version) = Version::parse(&info.latest_version) else {
            *self.progress.lock().expect("обновление") =
                Progress::Failed("версия релиза не разбирается".into());
            return;
        };

        let updates = self.clone();
        let url = info.download_url.clone();
        *self.progress.lock().expect("обновление") = Progress::Running(0.0);

        std::thread::spawn(move || {
            let installer = updates.installer.clone();
            let watched = updates.clone();

            // Доля обновляется отдельным потоком: установщик считает её сам,
            // а спрашивать его из главного цикла значило бы держать блокировку.
            let watcher = std::thread::spawn(move || loop {
                let current = watched.progress();
                if !matches!(current, Progress::Running(_)) {
                    return;
                }
                *watched.progress.lock().expect("обновление") =
                    Progress::Running(watched.installer.progress());
                std::thread::sleep(Duration::from_millis(200));
            });

            let outcome = installer.install(&version, &url);
            *updates.progress.lock().expect("обновление") = match outcome {
                Ok(()) => {
                    updates.store.clear();
                    Progress::Installed
                }
                Err(error) => Progress::Failed(error),
            };
            let _ = watcher.join();
        });
    }
}

/// Что плитка подвала говорит при наведении — дословно `SettingsFooter.help`
/// с macOS. `installing` — идёт установка найденной версии.
pub fn footer_hint(state: &CheckState, installing: bool) -> String {
    match state {
        CheckState::Idle | CheckState::Checking => "Проверить обновления".to_string(),
        CheckState::UpToDate(version) => format!("{version} — последняя версия"),
        CheckState::Available(info) if installing => {
            format!("Устанавливается {}…", info.latest_version)
        }
        CheckState::Available(info) => format!(
            "Доступна {} — нажмите, чтобы открыть окно обновления",
            info.latest_version
        ),
        CheckState::NoReleases => "Релизов пока нет".to_string(),
        CheckState::Failed(message) => message.clone(),
    }
}

/// Нажатие на плитку покажет обновление, а не проверит: иконка и имя
/// для экранного диктора меняются вместе — как `isUpdateAvailable` на macOS.
pub fn footer_shows_update(state: &CheckState, pending: bool) -> bool {
    pending || matches!(state, CheckState::Available(_))
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::sync::mpsc;

    use crate::checker::{CheckError, ReleaseChecker};

    /// Установщик, который отказывает, как настоящий на чужом адресе архива:
    /// граница системы, ставить в тестах некуда.
    struct Refusing;

    impl UpdateInstalling for Refusing {
        fn install(&self, _: &Version, url: &str) -> Result<(), String> {
            Err(format!("адрес не разрешён: {url}"))
        }

        fn progress(&self) -> f32 {
            0.0
        }
    }

    /// Источник релизов без сети. Релиз ставить некуда: адрес архива чужой,
    /// и установщик откажет до всякого запроса.
    struct Releases {
        latest: &'static str,
        /// Ворота: проверка ждёт, пока тест не откроет их, — так видно,
        /// что происходит с подвалом, пока ответа ещё нет.
        gate: Option<Mutex<mpsc::Receiver<()>>>,
    }

    impl ReleaseLooking for Releases {
        fn latest(&self, current: &Version) -> Result<UpdateInfo, CheckError> {
            if let Some(gate) = &self.gate {
                let _ = gate.lock().unwrap().recv();
            }
            let latest = Version::parse(self.latest).unwrap();
            Ok(UpdateInfo {
                current_version: current.to_string(),
                latest_version: self.latest.to_string(),
                release_url: format!("https://github.com/squaretus/weto/releases/tag/v{latest}"),
                download_url: "https://evil.example/weto.tar.zst".to_string(),
                is_newer: latest > *current,
            })
        }
    }

    fn updates(latest: &'static str, gate: Option<mpsc::Receiver<()>>) -> Arc<Updates> {
        let home = std::env::temp_dir().join(format!(
            "weto-updates-{}-{}",
            std::process::id(),
            UNIQUE.fetch_add(1, Ordering::SeqCst)
        ));
        let _ = std::fs::remove_dir_all(&home);
        Updates::new(
            home,
            Arc::new(Refusing),
            Arc::new(Releases {
                latest,
                gate: gate.map(Mutex::new),
            }),
            Version::parse("1.1.0").unwrap(),
        )
    }

    static UNIQUE: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

    fn wait_until(what: &str, done: impl Fn() -> bool) {
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while !done() {
            assert!(std::time::Instant::now() < deadline, "не дождались: {what}");
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    fn info(latest: &str) -> UpdateInfo {
        UpdateInfo {
            current_version: "1.1.0".to_string(),
            latest_version: latest.to_string(),
            release_url: String::new(),
            download_url: String::new(),
            is_newer: true,
        }
    }

    /// Подсказка плитки — дословно `SettingsFooter.help` с macOS, по состоянию.
    #[test]
    fn the_footer_hint_names_the_outcome_like_macos() {
        assert_eq!(
            footer_hint(&CheckState::Idle, false),
            "Проверить обновления"
        );
        assert_eq!(
            footer_hint(&CheckState::Checking, false),
            "Проверить обновления"
        );
        assert_eq!(
            footer_hint(&CheckState::UpToDate("1.1.0".into()), false),
            "1.1.0 — последняя версия"
        );
        assert_eq!(
            footer_hint(&CheckState::Available(info("1.2.0")), false),
            "Доступна 1.2.0 — нажмите, чтобы открыть окно обновления"
        );
        assert_eq!(
            footer_hint(&CheckState::Available(info("1.2.0")), true),
            "Устанавливается 1.2.0…"
        );
        assert_eq!(
            footer_hint(&CheckState::NoReleases, false),
            "Релизов пока нет"
        );
        assert_eq!(
            footer_hint(
                &CheckState::Failed("не спросить о релизах: нет сети".into()),
                false
            ),
            "не спросить о релизах: нет сети"
        );
    }

    #[test]
    fn the_footer_shows_an_update_once_one_is_known() {
        assert!(!footer_shows_update(&CheckState::Idle, false));
        assert!(!footer_shows_update(
            &CheckState::UpToDate("1.1.0".into()),
            false
        ));
        assert!(footer_shows_update(
            &CheckState::Available(info("1.2.0")),
            false
        ));
        // Находка остаётся находкой, даже если следующая проверка не дошла до сети.
        assert!(footer_shows_update(
            &CheckState::Failed("нет сети".into()),
            true
        ));
    }

    /// Пока идёт ручная проверка, плитка неактивна и фаза — «Проверка релиза…»;
    /// ответ с находкой открывает окно сам, как `presentDialog` на macOS.
    #[test]
    fn a_manual_check_is_busy_until_it_answers_and_then_asks_for_the_window() {
        let (open, gate) = mpsc::channel();
        let updates = updates("1.2.0", Some(gate));

        updates.check_now();
        assert_eq!(updates.state(), CheckState::Checking);
        assert!(updates.is_busy(), "плитка нажимается посреди проверки");
        assert_eq!(updates.update_progress().phase, UpdatePhase::Checking);

        // Повторное нажатие посреди проверки второй проверки не начинает.
        updates.check_now();

        open.send(()).unwrap();
        wait_until("ответ проверки", || {
            updates.state() != CheckState::Checking
        });

        assert!(matches!(updates.state(), CheckState::Available(_)));
        assert!(!updates.is_busy());
        let shown = updates.take_window_request().expect("окно не попросили");
        assert_eq!(shown.latest_version, "1.2.0");
        assert_eq!(
            updates.take_window_request(),
            None,
            "просьба забирается один раз"
        );
        assert_eq!(
            updates.pending().map(|i| i.latest_version).as_deref(),
            Some("1.2.0")
        );
    }

    /// Ручная проверка на канале, который принял соединение и замолчал, кончается
    /// отказом с причиной, а плитка снова нажимается. Без таймаута она висела
    /// «Проверка…» до перезапуска: вторую проверку `check_now` не начинает,
    /// пока идёт первая.
    #[test]
    fn a_manual_check_on_a_silent_channel_fails_and_frees_the_tile() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            let mut held = Vec::new();
            for stream in listener.incoming().flatten() {
                held.push(stream);
            }
        });
        let home = std::env::temp_dir().join(format!(
            "weto-updates-{}-{}",
            std::process::id(),
            UNIQUE.fetch_add(1, Ordering::SeqCst)
        ));
        let updates = Updates::new(
            home,
            Arc::new(Refusing),
            Arc::new(
                ReleaseChecker::new("squaretus/weto", "x86_64")
                    .with_api_url(format!("http://127.0.0.1:{port}/latest"))
                    .with_timeout(Duration::from_millis(300)),
            ),
            Version::parse("1.1.0").unwrap(),
        );

        updates.check_now();
        assert!(updates.is_busy());
        wait_until("отказ проверки", || {
            updates.state() != CheckState::Checking
        });

        assert!(
            matches!(updates.state(), CheckState::Failed(_)),
            "{:?}",
            updates.state()
        );
        assert!(!updates.is_busy(), "плитка осталась неактивной");
    }

    #[test]
    fn a_manual_check_without_news_asks_for_nothing() {
        let updates = updates("1.1.0", None);

        updates.check_now();
        wait_until("ответ проверки", || {
            updates.state() != CheckState::Checking
        });

        assert_eq!(updates.state(), CheckState::UpToDate("1.1.0".into()));
        assert_eq!(updates.take_window_request(), None);
        assert_eq!(updates.pending(), None);
    }

    /// Молчащая находка (пропуск, отсрочка) подвалу известна: нажатие
    /// показывает её, и баннер с окном снова о ней говорят.
    #[test]
    fn the_footer_brings_back_a_silent_finding() {
        let updates = updates("1.2.0", None);
        updates.apply(Examination {
            state: CheckState::Available(info("1.2.0")),
            finding: None,
        });
        assert_eq!(updates.pending(), None, "молчащая находка в баннере");

        let found = updates.found().expect("находку не вернули");

        assert_eq!(found.latest_version, "1.2.0");
        assert_eq!(updates.pending(), Some(found));
    }

    /// Отсрочка из меню и крестик окна прячут находку: баннер гаснет.
    #[test]
    fn closing_the_window_postpones_for_three_hours() {
        let updates = updates("1.2.0", None);
        updates.apply(Examination {
            state: CheckState::Available(info("1.2.0")),
            finding: Some(Finding::Prompt(info("1.2.0"))),
        });

        updates.dismiss();

        assert_eq!(updates.pending(), None);
        let remind_at = updates.store.deferral().remind_at.expect("отсрочки нет");
        let ahead = remind_at
            .duration_since(std::time::SystemTime::now())
            .unwrap();
        assert!(
            ahead > Duration::from_secs(3 * 3600 - 60) && ahead <= Duration::from_secs(3 * 3600),
            "крестик отложил на {ahead:?}"
        );
    }

    /// Отказ установки не остаётся в окне навсегда: следующая находка снова
    /// предлагает выбор.
    #[test]
    fn a_new_prompt_forgets_the_previous_failure() {
        let updates = updates("1.2.0", None);
        *updates.progress.lock().unwrap() = Progress::Failed("нет сети".into());

        updates.apply(Examination {
            state: CheckState::Available(info("1.2.0")),
            finding: Some(Finding::Prompt(info("1.2.0"))),
        });

        assert_eq!(updates.progress(), Progress::Idle);
    }

    /// Включённая автоустановка сразу ставит найденное, как на macOS; повтор
    /// того же значения ничего не делает — сверка тумблера с настройкой
    /// не должна оборачиваться установкой.
    #[test]
    fn turning_auto_install_on_installs_what_was_found() {
        let updates = updates("1.2.0", None);
        updates.set_auto_install(false);
        assert_eq!(
            updates.progress(),
            Progress::Idle,
            "выключение ставит обновление"
        );

        let mut found = info("1.2.0");
        found.download_url = "https://evil.example/weto.tar.zst".into();
        updates.apply(Examination {
            state: CheckState::Available(found),
            finding: None,
        });
        updates.set_auto_install(true);

        assert!(updates.auto_install());
        assert!(
            updates.store.deferral().auto_install,
            "настройка не записана"
        );
        wait_until("отказ установщика", || {
            matches!(updates.progress(), Progress::Failed(_))
        });

        // Тот же ответ ещё раз — не новое нажатие.
        updates.set_auto_install(true);
        assert!(matches!(updates.progress(), Progress::Failed(_)));
    }

    /// Баннер говорит фазами macOS. Установщик знает только долю скачанного:
    /// пока она меньше единицы — загрузка, дальше распаковка и переключение
    /// версии, то есть установка. Успех — тоже установка: перезапуск уже идёт,
    /// и «Доступно обновление» в этот миг было бы неправдой.
    #[test]
    fn the_installer_progress_reads_as_macos_phases() {
        assert_eq!(Progress::Idle.as_update_progress(), UpdateProgress::idle());
        assert_eq!(
            Progress::Running(0.25).as_update_progress(),
            UpdateProgress::new(UpdatePhase::Downloading, 0.25, None)
        );
        assert_eq!(
            Progress::Running(1.0).as_update_progress().phase,
            UpdatePhase::Installing
        );
        assert_eq!(
            Progress::Installed.as_update_progress().phase,
            UpdatePhase::Installing
        );
        assert_eq!(
            Progress::Failed("распаковка не удалась: диск полон".into()).as_update_progress(),
            UpdateProgress::new(
                UpdatePhase::Failed,
                0.0,
                Some("распаковка не удалась: диск полон".into())
            )
        );
    }
}
