//! Учёт эпизода охраны.

use weto_core::episode::EpisodeLedger;

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

/// Ровно та ошибка, ради которой учёт и вынесен в ядро: эпизод, закончившийся
/// безопасным выходом с уже известной причиной, обязан обнулять учёт. Иначе
/// следующее падение по той же причине писалось бы «запуск запрещён» вместо
/// «завершено», а множество пар росло бы без предела.
#[test]
fn a_finished_episode_resets_the_ledger() {
    let mut ledger = EpisodeLedger::new();
    ledger.remember(BLOCKED, [100, 101]);

    ledger.finish();

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
