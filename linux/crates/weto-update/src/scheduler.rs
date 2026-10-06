//! Когда спрашивать о новых версиях.
//!
//! На старте и раз в час — как на macOS. Интервал полем, а не константой:
//! тесту незачем ждать час, а продукту незачем знать, что это возможно.

use std::sync::mpsc::{self, Receiver};
use std::sync::Arc;
use std::time::Duration;

use crate::checker::{CheckError, ReleaseChecker};
use crate::policy::{decide, Outcome, UpdateDeferral, UpdateInfo};
use crate::version::Version;

pub const DEFAULT_INTERVAL: Duration = Duration::from_secs(3600);

/// Что решено делать с находкой. Тихий исход находкой не становится:
/// прятать баннер нечем, если о нём никто не узнал.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Finding {
    Prompt(UpdateInfo),
    Install(UpdateInfo),
}

/// Чем кончилась последняя проверка — порт `UpdateController.State` с macOS.
/// Его читает плитка подвала: подсказка называет исход, а нажатие на найденную
/// версию открывает окно, а не проверяет заново.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CheckState {
    Idle,
    /// Идёт ручная проверка: плитка неактивна до ответа.
    Checking,
    /// Текущая версия — последняя.
    UpToDate(String),
    /// Версия новее текущей. Есть и тогда, когда о ней молчат (пропуск,
    /// отсрочка): подвал о ней знает, баннер и окно — нет.
    Available(UpdateInfo),
    NoReleases,
    Failed(String),
}

/// Исход одной проверки: что знает подвал и что делать с находкой.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Examination {
    pub state: CheckState,
    pub finding: Option<Finding>,
}

/// Источник отсрочек. Трейтом — чтобы планировщик не знал, где они лежат,
/// а тест мог подставить свои.
pub trait DeferralReading: Send + Sync {
    fn deferral(&self) -> UpdateDeferral;
}

/// Опрос релизов. Отдельно от `ReleaseChecker`, чтобы тест не поднимал сервер
/// ради проверки расписания.
pub trait ReleaseLooking: Send + Sync {
    fn latest(&self, current: &Version) -> Result<UpdateInfo, CheckError>;
}

impl ReleaseLooking for ReleaseChecker {
    fn latest(&self, current: &Version) -> Result<UpdateInfo, CheckError> {
        ReleaseChecker::latest(self, current)
    }
}

impl Examination {
    fn bare(state: CheckState) -> Examination {
        Examination {
            state,
            finding: None,
        }
    }
}

pub struct UpdateScheduler {
    current: Version,
    checker: Arc<dyn ReleaseLooking>,
    deferrals: Arc<dyn DeferralReading>,
    interval: Duration,
}

impl UpdateScheduler {
    pub fn new(
        current: Version,
        checker: Arc<dyn ReleaseLooking>,
        deferrals: Arc<dyn DeferralReading>,
    ) -> UpdateScheduler {
        UpdateScheduler {
            current,
            checker,
            deferrals,
            interval: DEFAULT_INTERVAL,
        }
    }

    pub fn with_interval(mut self, interval: Duration) -> UpdateScheduler {
        self.interval = interval;
        self
    }

    /// Одна проверка. Ручная отличается тем, что игнорирует и пропуск,
    /// и отсрочку: это единственный и достаточный способ вернуть пропущенную
    /// версию, поэтому отдельной кнопки «снять пропуск» в настройках нет.
    pub fn check(&self, manual: bool) -> Option<Finding> {
        self.examine(manual).finding
    }

    /// Проверка вместе с исходом для подвала.
    pub fn examine(&self, manual: bool) -> Examination {
        let info = match self.checker.latest(&self.current) {
            Ok(info) => info,
            Err(CheckError::NoReleases) => return Examination::bare(CheckState::NoReleases),
            Err(error) => {
                // Молчание сети — обычное дело: сеть могла быть выключена
                // ровно в этот час. Настаивать не на чем, попробуем через час,
                // а подвал назовёт причину тому, кто нажал проверку.
                eprintln!("weto: проверка обновлений не удалась: {error}");
                return Examination::bare(CheckState::Failed(error.to_string()));
            }
        };
        if !info.is_newer {
            return Examination::bare(CheckState::UpToDate(info.current_version));
        }

        let deferral = if manual {
            UpdateDeferral::default()
        } else {
            self.deferrals.deferral()
        };

        let finding = match decide(&info, &deferral, std::time::SystemTime::now()) {
            Outcome::Silent => None,
            Outcome::Prompt => Some(Finding::Prompt(info.clone())),
            Outcome::Install => Some(Finding::Install(info.clone())),
        };
        Examination {
            state: CheckState::Available(info),
            finding,
        }
    }

    /// Запускает фоновый опрос: сразу и дальше по интервалу. Исход уходит
    /// каждый раз, а не только с находкой: подвал говорит и «последняя
    /// версия», и причину отказа.
    pub fn start(self) -> Receiver<Examination> {
        let (sender, receiver) = mpsc::channel();

        std::thread::Builder::new()
            .name("weto-updates".to_string())
            .spawn(move || loop {
                if sender.send(self.examine(false)).is_err() {
                    return;
                }
                std::thread::sleep(self.interval);
            })
            .expect("поток проверки обновлений не создался");

        receiver
    }
}
