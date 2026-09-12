//! Учёт остановленных процессов на настоящем временном каталоге.
//!
//! Подменять файловую систему здесь нечем и незачем: вопрос учёта — переживёт
//! ли обязательство падение weto, а это свойство диска, а не нашего типа.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use weto_config::paths::Paths;
use weto_config::stopped::{StoppedLedger, StoppedLedgerReadout, StoppedProcess};

fn entry(pid: i32, is_shell: bool) -> StoppedProcess {
    StoppedProcess {
        pid,
        executable_path: format!("/usr/bin/цель-{pid}"),
        stopped_at: UNIX_EPOCH + Duration::from_secs(1_756_300_366),
        is_shell,
    }
}

/// Путь назван каноном и повторяется установщиком, и проверяется он здесь,
/// а не на глаз.
#[test]
fn the_ledger_lives_next_to_the_journals_in_the_state_directory() {
    let paths = Paths::rooted("/home/тест".into());

    assert_eq!(
        paths.stopped_file(),
        std::path::Path::new("/home/тест/.local/state/weto/stopped.json")
    );
}

/// Круг: записали, прочитали, получили то же самое — включая признак шелла
/// и момент остановки.
#[test]
fn entries_survive_a_round_trip_through_the_file() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("weto/stopped.json");

    let mut ledger = StoppedLedger::default();
    assert!(ledger.add(&[entry(100, true), entry(200, false)]));
    ledger.save(&path).unwrap();

    let loaded = StoppedLedger::load(&path);

    assert_eq!(loaded.entries(), ledger.entries());
    assert_eq!(loaded.pids(), vec![100, 200]);
    assert!(loaded.entries()[0].is_shell, "шелл остаётся шеллом");
    assert_eq!(
        loaded.entries()[1].stopped_at,
        UNIX_EPOCH + Duration::from_secs(1_756_300_366)
    );
    assert!(!loaded.started_from_corrupted_file());
}

/// Один и тот же pid дважды в учёт не попадает, порядок добавления сохраняется:
/// продолжение идёт по нему в обратную сторону.
#[test]
fn the_same_pid_is_not_recorded_twice_and_the_order_is_kept() {
    let mut ledger = StoppedLedger::default();

    assert!(ledger.add(&[entry(200, false)]));
    assert!(ledger.add(&[entry(200, false), entry(201, false)]));
    assert!(!ledger.add(&[entry(201, false)]), "добавлять нечего");

    assert_eq!(ledger.pids(), vec![200, 201]);
}

/// Число ядро переиспользует, и запись про мёртвого владельца этого числа
/// не имеет права вытеснить свежую: пара «pid + путь» у них разная, а значит
/// это разные процессы — так их и различает всё остальное (`pause`, `settle`).
/// Дедупликация по одному pid теряла свежую запись целиком: SIGSTOP ей уже
/// послан, в учёт она не попадала, следующий проход вычёркивал по несовпадению
/// путей чужую — и размораживать цель становилось некому.
///
/// Свежая встаёт в хвост: учёт хранит стоп-порядок, `resume` идёт по нему
/// в обратную сторону, а остановлена она позже всего, что уже лежит.
#[test]
fn a_recycled_pid_replaces_the_stale_entry_instead_of_dropping_the_fresh_one() {
    let mut ledger = StoppedLedger::default();
    ledger.add(&[entry(100, false), entry(200, false), entry(300, false)]);

    let fresh = StoppedProcess {
        pid: 200,
        executable_path: "/usr/bin/claude".to_string(),
        stopped_at: UNIX_EPOCH + Duration::from_secs(1_756_400_000),
        is_shell: false,
    };
    assert!(
        ledger.add(std::slice::from_ref(&fresh)),
        "учёт обязан измениться"
    );

    assert_eq!(
        ledger
            .entries()
            .iter()
            .map(|e| e.executable_path.as_str())
            .collect::<Vec<_>>(),
        vec!["/usr/bin/цель-100", "/usr/bin/цель-300", "/usr/bin/claude"],
        "запись про мёртвого владельца pid уступает место свежей"
    );
    assert_eq!(ledger.pids(), vec![100, 300, 200]);
    assert_eq!(ledger.entries()[2].stopped_at, fresh.stopped_at);
}

/// Порядок партии при этом свой: переставить местами цель с её шеллом значило бы
/// сломать контракт сигналов, по которому `resume` идёт задом наперёд.
#[test]
fn a_replacement_keeps_the_order_of_its_own_batch() {
    let mut ledger = StoppedLedger::default();
    ledger.add(&[entry(200, true)]);

    ledger.add(&[
        StoppedProcess {
            pid: 200,
            executable_path: "/usr/bin/zsh".to_string(),
            stopped_at: UNIX_EPOCH + Duration::from_secs(1_756_400_000),
            is_shell: true,
        },
        entry(201, false),
        entry(202, false),
    ]);

    assert_eq!(ledger.pids(), vec![200, 201, 202]);
}

#[test]
fn removal_and_clearing_report_whether_anything_changed() {
    let mut ledger = StoppedLedger::default();
    ledger.add(&[entry(1, false), entry(2, false)]);

    assert!(ledger.remove(&[2]));
    assert!(!ledger.remove(&[2]), "второй раз удалять нечего");
    assert_eq!(ledger.pids(), vec![1]);

    assert!(ledger.clear());
    assert!(!ledger.clear());
    assert!(ledger.entries().is_empty());
}

/// Файла ещё нет — легитимно пусто, и это не порча: «не было» и «было,
/// но не прочиталось» обязаны различаться.
#[test]
fn a_missing_file_is_not_reported_as_corrupted() {
    let tmp = tempfile::tempdir().unwrap();
    let readout = StoppedLedgerReadout::load(&tmp.path().join("stopped.json"));

    assert!(readout.entries().is_empty());
    assert!(!readout.is_corrupted());
}

/// Порча видна на границе, а не тонет в пустом списке: список пуст (как
/// и раньше), старт не блокируется, но механизм восстановления знает, что
/// обязательство «вернуть остановленным SIGCONT» осталось невыполненным.
#[test]
fn a_corrupt_file_reads_as_empty_but_the_failure_stays_visible() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("stopped.json");
    std::fs::write(&path, "{не json").unwrap();

    let readout = StoppedLedgerReadout::load(&path);
    assert!(readout.entries().is_empty());
    assert!(readout.is_corrupted());

    let ledger = StoppedLedger::load(&path);
    assert!(ledger.entries().is_empty());
    assert!(ledger.started_from_corrupted_file());
}

/// Легитимно пустой учёт ложной тревоги не поднимает.
#[test]
fn a_legitimately_empty_ledger_does_not_claim_corruption() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("stopped.json");
    StoppedLedger::default().save(&path).unwrap();

    let ledger = StoppedLedger::load(&path);

    assert!(ledger.entries().is_empty());
    assert!(!ledger.started_from_corrupted_file());
}

/// Запись идёт через временный файл рядом и `rename` поверх: оборванная
/// на полуслове запись обязана оставить прежний учёт целым, а не половину
/// нового. Подложенный мусор по временному пути доказывает, что путь этот
/// используется и не остаётся после записи.
#[test]
fn the_write_goes_through_a_temporary_file_next_to_the_target() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("stopped.json");
    let temporary = tmp.path().join("stopped.json.tmp");

    let mut ledger = StoppedLedger::default();
    ledger.add(&[entry(1, false)]);
    ledger.save(&path).unwrap();

    std::fs::write(&temporary, "мусор от оборванной записи").unwrap();
    ledger.add(&[entry(2, false)]);
    ledger.save(&path).unwrap();

    assert_eq!(StoppedLedger::load(&path).pids(), vec![1, 2]);
    assert!(
        !temporary.exists(),
        "временный файл поглощён rename, а не оставлен рядом"
    );
}

/// Каталог заводится сам: до первой паузы `~/.local/state/weto` может
/// не существовать вовсе.
#[test]
fn saving_creates_the_state_directory() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("нет/такого/каталога/stopped.json");

    let mut ledger = StoppedLedger::default();
    ledger.add(&[entry(7, false)]);
    ledger.save(&path).unwrap();

    assert!(path.exists());
}

/// Время в файле — строкой ISO 8601, как в журналах: файл читают руками,
/// и `{secs_since_epoch}` в нём никому ничего не объясняет.
#[test]
fn the_moment_is_written_as_an_iso_8601_string() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("stopped.json");
    let mut ledger = StoppedLedger::default();
    ledger.add(&[StoppedProcess {
        pid: 5,
        executable_path: "/usr/bin/nano".to_string(),
        stopped_at: SystemTime::UNIX_EPOCH + Duration::from_secs(1_756_300_366),
        is_shell: false,
    }]);
    ledger.save(&path).unwrap();

    let text = std::fs::read_to_string(&path).unwrap();

    assert!(text.contains("\"stoppedAt\": \"2025-08-27T"), "{text}");
    assert!(text.contains("\"executablePath\""), "{text}");
    assert!(text.contains("\"isShell\""), "{text}");
}
