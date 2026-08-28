//! Журнал проверок подключения.
//!
//! Зеркало макосного `CheckLogStoreTests`: пишется не всё подряд, потому что
//! расписание ходит раз в пять секунд и полсотни записей стали бы четырьмя
//! минутами истории.

use std::time::{Duration, UNIX_EPOCH};

use weto_config::checks::{CheckEvent, CheckLog, CheckOutcome, CheckTrigger, CAPACITY};

fn check(trigger: CheckTrigger, outcome: CheckOutcome, seconds: u64) -> CheckEvent {
    CheckEvent {
        id: format!("check-{seconds}"),
        at: UNIX_EPOCH + Duration::from_secs(seconds),
        trigger,
        outcome,
        fingerprint: Some("out=wg0/10.2.0.5".to_string()),
        duration_milliseconds: None,
        ip: None,
        country: None,
        confirmed_country: None,
        confirm_source: None,
        services: Vec::new(),
        detail: None,
    }
}

/// Ровно тот случай, ради которого журнал проверок и заведён: пользователь нажал,
/// запрос не ушёл, завершений не было — и следа не оставалось.
#[test]
fn a_press_that_sent_nothing_is_recorded() {
    let mut log = CheckLog::default();

    assert!(log.append(check(
        CheckTrigger::Manual,
        CheckOutcome::SkippedProbeInFlight,
        1
    )));

    assert_eq!(log.entries().len(), 1);
    assert_eq!(log.entries()[0].trigger, CheckTrigger::Manual);
}

/// Рутинная удача расписания в журнал не идёт: раз в пять секунд она съела бы
/// всю ёмкость за четыре минуты и не сказала бы ничего.
#[test]
fn a_routine_scheduled_success_is_not_recorded() {
    let mut log = CheckLog::default();

    assert!(!log.append(check(CheckTrigger::Schedule, CheckOutcome::Answered, 1)));

    assert!(log.entries().is_empty());
}

/// А вот состоявшийся запрос без ответа — идёт: это и есть отладочный материал.
#[test]
fn a_scheduled_request_without_an_answer_is_recorded() {
    let mut log = CheckLog::default();

    assert!(log.append(check(CheckTrigger::Schedule, CheckOutcome::Failed, 1)));

    assert_eq!(log.entries().len(), 1);
}

#[test]
fn network_and_settings_checks_are_always_recorded() {
    let mut log = CheckLog::default();

    log.append(check(
        CheckTrigger::NetworkChange,
        CheckOutcome::Answered,
        1,
    ));
    log.append(check(
        CheckTrigger::SettingsChange,
        CheckOutcome::Answered,
        2,
    ));

    assert_eq!(log.entries().len(), 2);
}

#[test]
fn capacity_is_fifty_and_the_freshest_stay() {
    assert_eq!(CAPACITY, 50);

    let mut log = CheckLog::default();
    for second in 0..70 {
        log.append(check(
            CheckTrigger::Manual,
            CheckOutcome::SkippedProbeInFlight,
            second,
        ));
    }

    assert_eq!(log.entries().len(), CAPACITY);
    assert_eq!(
        log.entries()[0].at,
        UNIX_EPOCH + Duration::from_secs(69),
        "свежие сверху"
    );
    assert_eq!(
        log.entries()[CAPACITY - 1].at,
        UNIX_EPOCH + Duration::from_secs(20)
    );
}

#[test]
fn a_check_log_survives_a_round_trip() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("state/checks.json");

    let mut log = CheckLog::default();
    log.append(check(CheckTrigger::Manual, CheckOutcome::Failed, 7));
    log.save(&path).unwrap();

    assert_eq!(CheckLog::load(&path), log);
}

/// Журнал — история, а не данные. Испорченный файл не должен мешать охране.
#[test]
fn a_corrupt_check_log_reads_as_empty() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("checks.json");
    std::fs::write(&path, "{ поломка").unwrap();

    assert!(CheckLog::load(&path).entries().is_empty());
}
