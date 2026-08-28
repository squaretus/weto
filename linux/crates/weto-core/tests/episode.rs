//! Учёт эпизода охраны.

use weto_core::episode::EpisodeLedger;

const PENDING: &str = "Подключение ещё не проверено";
const BLOCKED: &str = "Адрес 1.2.3.4 в чёрном списке";

fn pids(items: Vec<&i32>) -> Vec<i32> {
    items.into_iter().copied().collect()
}

#[test]
fn the_same_process_under_the_same_reason_is_written_once() {
    let mut ledger = EpisodeLedger::new();
    let killed = vec![100, 101];

    assert_eq!(pids(ledger.fresh(&killed, BLOCKED, |p| *p)), vec![100, 101]);
    ledger.remember(BLOCKED, [100, 101]);

    assert!(ledger.fresh(&killed, BLOCKED, |p| *p).is_empty());
}

#[test]
fn a_relaunched_process_is_written_again() {
    let mut ledger = EpisodeLedger::new();
    ledger.remember(BLOCKED, [100]);

    let killed = vec![100, 777];

    assert_eq!(pids(ledger.fresh(&killed, BLOCKED, |p| *p)), vec![777]);
    assert!(!ledger.is_new_reason(BLOCKED), "причина уже описана");
}

/// Уточнение причины не должно заводить второй набор записей: процессы те же,
/// падение то же, изменился только текст.
#[test]
fn settling_the_reason_moves_the_dedup_key_with_it() {
    let mut ledger = EpisodeLedger::new();
    ledger.begin_pending("эпизод".to_string());
    ledger.remember(PENDING, [100, 101]);

    assert_eq!(ledger.settle(PENDING, BLOCKED).as_deref(), Some("эпизод"));

    let killed = vec![100, 101];
    assert!(
        ledger.fresh(&killed, BLOCKED, |p| *p).is_empty(),
        "те же процессы под уточнённой причиной не новые"
    );
    assert!(!ledger.is_new_reason(BLOCKED));
}

#[test]
fn settling_without_a_pending_episode_changes_nothing() {
    let mut ledger = EpisodeLedger::new();
    assert_eq!(ledger.settle(PENDING, BLOCKED), None);
}

/// Ровно та ошибка, ради которой учёт и вынесен в ядро: эпизод, закончившийся
/// безопасным выходом с уже известной причиной, обнулял учёт только когда был
/// неразобранным. Следующее падение по той же причине писалось «запуск
/// запрещён» вместо «завершено», а множество пар росло без предела.
#[test]
fn a_finished_episode_resets_the_ledger_even_without_a_pending_id() {
    let mut ledger = EpisodeLedger::new();
    ledger.remember(BLOCKED, [100, 101]);

    assert_eq!(ledger.finish(), None, "уточнять нечего");

    let killed = vec![100, 101];
    assert!(
        ledger.is_new_reason(BLOCKED),
        "новое падение — новая причина"
    );
    assert_eq!(
        pids(ledger.fresh(&killed, BLOCKED, |p| *p)),
        vec![100, 101],
        "и те же процессы описываются заново"
    );
}

#[test]
fn a_finished_pending_episode_is_returned_for_its_outcome() {
    let mut ledger = EpisodeLedger::new();
    ledger.begin_pending("эпизод".to_string());
    ledger.remember(PENDING, [100]);

    assert_eq!(ledger.finish().as_deref(), Some("эпизод"));
    assert_eq!(ledger.finish(), None, "второй раз дописывать нечего");
}
