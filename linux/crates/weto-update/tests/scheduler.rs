//! Расписание проверок и хранилище отсрочек.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use weto_update::checker::CheckError;
use weto_update::policy::{RemindInterval, UpdateDeferral, UpdateInfo, MAXIMUM_REMIND_INTERVAL};
use weto_update::scheduler::{
    CheckState, DeferralReading, Examination, Finding, ReleaseLooking, UpdateScheduler,
};
use weto_update::store::UpdateStore;
use weto_update::version::Version;

#[derive(Clone)]
struct FakeReleases {
    latest: String,
    /// Ответ вместо релиза: нет релизов вовсе или отказ сети.
    failure: Option<fn() -> CheckError>,
    calls: Arc<AtomicUsize>,
}

impl FakeReleases {
    fn at(version: &str) -> FakeReleases {
        FakeReleases {
            latest: version.to_string(),
            failure: None,
            calls: Arc::new(AtomicUsize::new(0)),
        }
    }

    fn failing(failure: fn() -> CheckError) -> FakeReleases {
        FakeReleases {
            failure: Some(failure),
            ..FakeReleases::at("0.0.0")
        }
    }
}

impl ReleaseLooking for FakeReleases {
    fn latest(&self, current: &Version) -> Result<UpdateInfo, CheckError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        if let Some(failure) = self.failure {
            return Err(failure());
        }
        let latest = Version::parse(&self.latest).unwrap();
        Ok(UpdateInfo {
            current_version: current.to_string(),
            latest_version: self.latest.clone(),
            release_url: format!(
                "https://github.com/squaretus/weto/releases/tag/v{}",
                self.latest
            ),
            download_url: format!(
                "https://github.com/squaretus/weto/releases/download/v{}/weto-{}-x86_64-linux.tar.zst",
                self.latest, self.latest
            ),
            is_newer: latest > *current,
        })
    }
}

#[derive(Clone, Default)]
struct FakeDeferrals(Arc<Mutex<UpdateDeferral>>);

impl DeferralReading for FakeDeferrals {
    fn deferral(&self) -> UpdateDeferral {
        self.0.lock().unwrap().clone()
    }
}

fn scheduler(releases: FakeReleases, deferrals: FakeDeferrals, current: &str) -> UpdateScheduler {
    UpdateScheduler::new(
        Version::parse(current).unwrap(),
        Arc::new(releases),
        Arc::new(deferrals),
    )
}

#[test]
fn a_newer_version_becomes_a_prompt() {
    let finding =
        scheduler(FakeReleases::at("1.2.0"), FakeDeferrals::default(), "1.1.0").check(false);

    assert!(matches!(finding, Some(Finding::Prompt(_))));
}

#[test]
fn the_same_version_produces_nothing() {
    let finding =
        scheduler(FakeReleases::at("1.1.0"), FakeDeferrals::default(), "1.1.0").check(false);

    assert_eq!(finding, None);
}

/// Тихий исход прячет и окно, и баннер: до потребителя он не доходит вовсе.
#[test]
fn a_skipped_version_stays_silent() {
    let deferrals = FakeDeferrals::default();
    deferrals.0.lock().unwrap().skipped_version = Some("1.2.0".to_string());

    let finding = scheduler(FakeReleases::at("1.2.0"), deferrals, "1.1.0").check(false);

    assert_eq!(finding, None);
}

/// Ручная проверка игнорирует и пропуск, и отсрочку — единственный
/// и достаточный способ вернуть пропущенную версию.
#[test]
fn a_manual_check_ignores_both_skip_and_snooze() {
    let deferrals = FakeDeferrals::default();
    {
        let mut state = deferrals.0.lock().unwrap();
        state.skipped_version = Some("1.2.0".to_string());
        state.remind_at = SystemTime::now().checked_add(Duration::from_secs(3600));
    }

    let finding = scheduler(FakeReleases::at("1.2.0"), deferrals, "1.1.0").check(true);

    assert!(matches!(finding, Some(Finding::Prompt(_))));
}

#[test]
fn auto_install_turns_the_finding_into_an_install() {
    let deferrals = FakeDeferrals::default();
    deferrals.0.lock().unwrap().auto_install = true;

    let finding = scheduler(FakeReleases::at("1.2.0"), deferrals, "1.1.0").check(false);

    assert!(matches!(finding, Some(Finding::Install(_))));
}

// --- исход проверки для подвала ---------------------------------------------

/// Подсказка плитки в подвале называет исход проверки, как `UpdateController.State`
/// на macOS: свежая версия, релизов нет, отказ — каждый своим состоянием.
#[test]
fn the_same_version_reads_as_up_to_date() {
    let examination =
        scheduler(FakeReleases::at("1.1.0"), FakeDeferrals::default(), "1.1.0").examine(true);

    assert_eq!(
        examination,
        Examination {
            state: CheckState::UpToDate("1.1.0".to_string()),
            finding: None,
        }
    );
}

#[test]
fn a_repository_without_releases_says_so() {
    let examination = scheduler(
        FakeReleases::failing(|| CheckError::NoReleases),
        FakeDeferrals::default(),
        "1.1.0",
    )
    .examine(true);

    assert_eq!(examination.state, CheckState::NoReleases);
    assert_eq!(examination.finding, None);
}

#[test]
fn a_failed_request_carries_its_reason() {
    let examination = scheduler(
        FakeReleases::failing(|| CheckError::Request("нет сети".to_string())),
        FakeDeferrals::default(),
        "1.1.0",
    )
    .examine(true);

    assert_eq!(
        examination.state,
        CheckState::Failed("не спросить о релизах: нет сети".to_string())
    );
    assert_eq!(examination.finding, None);
}

/// Пропущенная версия молчит, но подвал о ней знает: нажатие на плитку
/// открывает окно — так на macOS ручная проверка возвращает пропуск.
#[test]
fn a_silent_finding_is_still_available_to_the_footer() {
    let deferrals = FakeDeferrals::default();
    deferrals.0.lock().unwrap().skipped_version = Some("1.2.0".to_string());

    let examination = scheduler(FakeReleases::at("1.2.0"), deferrals, "1.1.0").examine(false);

    assert!(
        matches!(&examination.state, CheckState::Available(info) if info.latest_version == "1.2.0")
    );
    assert_eq!(examination.finding, None);
}

#[test]
fn a_prompt_is_available_too() {
    let examination =
        scheduler(FakeReleases::at("1.2.0"), FakeDeferrals::default(), "1.1.0").examine(false);

    assert!(matches!(examination.state, CheckState::Available(_)));
    assert!(matches!(examination.finding, Some(Finding::Prompt(_))));
}

// --- сроки отсрочки ----------------------------------------------------------

/// Пункты меню «Напомнить позже» — те же три срока, что `RemindInterval`
/// на macOS, а крестик окна — три часа.
#[test]
fn the_remind_intervals_are_one_three_and_six_hours() {
    assert_eq!(
        RemindInterval::ALL.map(RemindInterval::duration),
        [
            Duration::from_secs(3600),
            Duration::from_secs(3 * 3600),
            Duration::from_secs(6 * 3600),
        ]
    );
    assert_eq!(RemindInterval::ON_CLOSE, RemindInterval::ThreeHours);
}

/// Самый долгий срок меню обязан помещаться под потолок отсрочки: иначе
/// «через 6 часов» читалось бы как испорченная дата и окно всплывало сразу.
#[test]
fn every_remind_interval_fits_under_the_ceiling() {
    for interval in RemindInterval::ALL {
        assert!(interval.duration() <= MAXIMUM_REMIND_INTERVAL);
    }
}

/// Отсрочка из меню молчит до срока у настоящего хранилища и настоящей
/// проверки — каждым из трёх сроков, включая самый долгий.
#[test]
fn each_remind_interval_silences_the_next_scheduled_check() {
    for interval in RemindInterval::ALL {
        let tmp = tempfile::tempdir().unwrap();
        let store = Arc::new(UpdateStore::new(tmp.path().into()));
        store.remind_later(interval.duration());

        let scheduled = UpdateScheduler::new(
            Version::parse("1.1.0").unwrap(),
            Arc::new(FakeReleases::at("1.2.0")),
            Arc::new(StoreReader(store.clone())),
        );

        assert_eq!(scheduled.check(false), None, "{interval:?} не отложил окно");
        assert!(
            matches!(scheduled.check(true), Some(Finding::Prompt(_))),
            "ручная проверка обязана пройти сквозь отсрочку {interval:?}"
        );
    }
}

struct StoreReader(Arc<UpdateStore>);

impl DeferralReading for StoreReader {
    fn deferral(&self) -> UpdateDeferral {
        self.0.deferral()
    }
}

#[test]
fn the_check_runs_at_start_and_then_on_the_interval() {
    let releases = FakeReleases::at("1.2.0");
    let calls = releases.calls.clone();

    let receiver = scheduler(releases, FakeDeferrals::default(), "1.1.0")
        .with_interval(Duration::from_millis(50))
        .start();

    // Первая находка приходит сразу, не дожидаясь интервала.
    let first = receiver
        .recv_timeout(Duration::from_secs(2))
        .expect("первой проверки не было");
    assert!(matches!(first.finding, Some(Finding::Prompt(_))));
    std::thread::sleep(Duration::from_millis(180));

    assert!(
        calls.load(Ordering::SeqCst) >= 3,
        "проверок было {}",
        calls.load(Ordering::SeqCst)
    );
}

// --- хранилище -------------------------------------------------------------

#[test]
fn a_skip_survives_a_restart() {
    let tmp = tempfile::tempdir().unwrap();
    UpdateStore::new(tmp.path().into()).skip("1.2.0");

    let deferral = UpdateStore::new(tmp.path().into()).deferral();

    assert_eq!(deferral.skipped_version.as_deref(), Some("1.2.0"));
}

/// Отсрочка хранится абсолютной датой: относительный срок после перезапуска
/// начинался бы заново, и окно всплывало бы на каждом старте.
#[test]
fn a_snooze_is_stored_as_an_absolute_date() {
    let tmp = tempfile::tempdir().unwrap();
    let store = UpdateStore::new(tmp.path().into());

    store.remind_later(Duration::from_secs(3600));
    let remind_at = store.deferral().remind_at.expect("отсрочка сохранилась");

    let ahead = remind_at.duration_since(SystemTime::now()).unwrap();
    assert!(ahead > Duration::from_secs(3500) && ahead < Duration::from_secs(3700));
}

#[test]
fn a_successful_install_clears_the_previous_answers() {
    let tmp = tempfile::tempdir().unwrap();
    let store = UpdateStore::new(tmp.path().into());

    store.skip("1.2.0");
    store.remind_later(Duration::from_secs(3600));
    store.clear();

    let deferral = store.deferral();
    assert_eq!(deferral.skipped_version, None);
    assert_eq!(deferral.remind_at, None);
}

/// Испорченный файл — состояние диалога, а не данные: молчать об обновлениях
/// из-за нечитаемой строки хуже, чем забыть отсрочку.
#[test]
fn a_corrupt_store_reads_as_nothing_deferred() {
    let tmp = tempfile::tempdir().unwrap();
    std::fs::write(tmp.path().join("update.json"), "{ поломка").unwrap();

    let deferral = UpdateStore::new(tmp.path().into()).deferral();

    assert_eq!(deferral, UpdateDeferral::default());
}
