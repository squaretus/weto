//! Расписание проверок и хранилище отсрочек.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use weto_update::policy::{UpdateDeferral, UpdateInfo};
use weto_update::scheduler::{DeferralReading, Finding, ReleaseLooking, UpdateScheduler};
use weto_update::store::UpdateStore;
use weto_update::version::Version;

#[derive(Clone)]
struct FakeReleases {
    latest: String,
    calls: Arc<AtomicUsize>,
}

impl FakeReleases {
    fn at(version: &str) -> FakeReleases {
        FakeReleases {
            latest: version.to_string(),
            calls: Arc::new(AtomicUsize::new(0)),
        }
    }
}

impl ReleaseLooking for FakeReleases {
    fn latest(&self, current: &Version) -> Option<UpdateInfo> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        let latest = Version::parse(&self.latest).unwrap();
        Some(UpdateInfo {
            latest_version: self.latest.clone(),
            download_url: format!(
                "https://github.com/squaretus/weto/releases/download/v{}/weto-{}-x86_64-linux.tar.zst",
                self.latest, self.latest
            ),
            release_notes: Some("Заметки".to_string()),
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

#[test]
fn the_check_runs_at_start_and_then_on_the_interval() {
    let releases = FakeReleases::at("1.2.0");
    let calls = releases.calls.clone();

    let receiver = scheduler(releases, FakeDeferrals::default(), "1.1.0")
        .with_interval(Duration::from_millis(50))
        .start();

    // Первая находка приходит сразу, не дожидаясь интервала.
    assert!(receiver.recv_timeout(Duration::from_secs(2)).is_ok());
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
