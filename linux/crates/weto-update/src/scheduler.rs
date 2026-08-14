//! Когда спрашивать о новых версиях.
//!
//! На старте и раз в час — как на macOS. Интервал полем, а не константой:
//! тесту незачем ждать час, а продукту незачем знать, что это возможно.

use std::sync::mpsc::{self, Receiver};
use std::sync::Arc;
use std::time::Duration;

use crate::checker::ReleaseChecker;
use crate::policy::{decide, Outcome, UpdateDeferral, UpdateInfo};
use crate::version::Version;

pub const DEFAULT_INTERVAL: Duration = Duration::from_secs(3600);

/// Что решено делать с находкой. Тихий исход до потребителя не доходит вовсе:
/// прятать баннер нечем, если о нём никто не узнал.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Finding {
    Prompt(UpdateInfo),
    Install(UpdateInfo),
}

/// Источник отсрочек. Трейтом — чтобы планировщик не знал, где они лежат,
/// а тест мог подставить свои.
pub trait DeferralReading: Send + Sync {
    fn deferral(&self) -> UpdateDeferral;
}

/// Опрос релизов. Отдельно от `ReleaseChecker`, чтобы тест не поднимал сервер
/// ради проверки расписания.
pub trait ReleaseLooking: Send + Sync {
    fn latest(&self, current: &Version) -> Option<UpdateInfo>;
}

impl ReleaseLooking for ReleaseChecker {
    fn latest(&self, current: &Version) -> Option<UpdateInfo> {
        match ReleaseChecker::latest(self, current) {
            Ok(info) => Some(info),
            Err(error) => {
                // Молчание сети — обычное дело: сеть могла быть выключена
                // ровно в этот час. Настаивать не на чем, попробуем через час.
                eprintln!("weto: проверка обновлений не удалась: {error}");
                None
            }
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
        let info = self.checker.latest(&self.current)?;
        if !info.is_newer {
            return None;
        }

        let deferral = if manual {
            UpdateDeferral::default()
        } else {
            self.deferrals.deferral()
        };

        match decide(&info, &deferral, std::time::SystemTime::now()) {
            Outcome::Silent => None,
            Outcome::Prompt => Some(Finding::Prompt(info)),
            Outcome::Install => Some(Finding::Install(info)),
        }
    }

    /// Запускает фоновый опрос: сразу и дальше по интервалу.
    pub fn start(self) -> Receiver<Finding> {
        let (sender, receiver) = mpsc::channel();

        std::thread::Builder::new()
            .name("weto-updates".to_string())
            .spawn(move || loop {
                if let Some(finding) = self.check(false) {
                    if sender.send(finding).is_err() {
                        return;
                    }
                }
                std::thread::sleep(self.interval);
            })
            .expect("поток проверки обновлений не создался");

        receiver
    }
}
