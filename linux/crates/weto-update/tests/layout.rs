//! Раскладка версий, атомарность подмены и откат.

use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;

use weto_update::layout::Layout;
use weto_update::rollback::{roll_back_if_needed, LaunchMarker};
use weto_update::version::Version;

fn prepare(root: &Path, versions: &[&str]) -> Layout {
    let layout = Layout::new(root.to_path_buf());
    for version in versions {
        let dir = layout.install_dir(&Version::parse(version).unwrap());
        std::fs::create_dir_all(dir.join("bin")).unwrap();
        std::fs::write(dir.join("bin/weto"), version).unwrap();
    }
    layout
}

#[test]
fn activating_a_version_points_current_at_it() {
    let tmp = tempfile::tempdir().unwrap();
    let layout = prepare(tmp.path(), &["0.0.1", "0.0.2"]);

    layout.activate(&Version::parse("0.0.2").unwrap()).unwrap();

    assert_eq!(layout.current_version().unwrap().to_string(), "0.0.2");
    let binary = std::fs::read_to_string(layout.current_symlink().join("bin/weto")).unwrap();
    assert_eq!(binary, "0.0.2", "симлинк ведёт в нужную версию");
}

#[test]
fn activating_a_missing_version_is_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let layout = prepare(tmp.path(), &["0.0.1"]);

    assert!(layout.activate(&Version::parse("9.9.9").unwrap()).is_err());
}

/// Между снятием старого симлинка и созданием нового не должно быть мгновения,
/// когда приложения нет на диске: в это окно попадёт запуск из ярлыка.
#[test]
fn there_is_no_instant_without_a_current_symlink() {
    let tmp = tempfile::tempdir().unwrap();
    let layout = prepare(tmp.path(), &["0.0.1", "0.0.2"]);
    layout.activate(&Version::parse("0.0.1").unwrap()).unwrap();

    let path = layout.current_symlink();
    let stop = Arc::new(AtomicBool::new(false));
    let misses = Arc::new(AtomicUsize::new(0));

    let watcher = {
        let stop = stop.clone();
        let misses = misses.clone();
        std::thread::spawn(move || {
            while !stop.load(Ordering::SeqCst) {
                if std::fs::read_link(&path).is_err() {
                    misses.fetch_add(1, Ordering::SeqCst);
                }
            }
        })
    };

    for _ in 0..200 {
        layout.activate(&Version::parse("0.0.2").unwrap()).unwrap();
        layout.activate(&Version::parse("0.0.1").unwrap()).unwrap();
    }

    stop.store(true, Ordering::SeqCst);
    watcher.join().unwrap();

    assert_eq!(
        misses.load(Ordering::SeqCst),
        0,
        "читатель увидел отсутствие симлинка — подмена не атомарна"
    );
}

/// Одна предыдущая версия остаётся не ради трафика, а ради отката.
#[test]
fn pruning_keeps_the_current_version_and_one_before_it() {
    let tmp = tempfile::tempdir().unwrap();
    let layout = prepare(tmp.path(), &["0.0.1", "0.0.2", "0.0.3"]);
    layout.activate(&Version::parse("0.0.3").unwrap()).unwrap();

    layout.prune(1).unwrap();

    assert!(layout
        .install_dir(&Version::parse("0.0.3").unwrap())
        .exists());
    assert!(layout
        .install_dir(&Version::parse("0.0.2").unwrap())
        .exists());
    assert!(!layout
        .install_dir(&Version::parse("0.0.1").unwrap())
        .exists());
}

#[test]
fn versions_sort_numerically_not_lexicographically() {
    let tmp = tempfile::tempdir().unwrap();
    let layout = prepare(tmp.path(), &["0.9.0", "0.10.0"]);

    let versions: Vec<String> = layout
        .installed_versions()
        .iter()
        .map(ToString::to_string)
        .collect();

    assert_eq!(versions, vec!["0.9.0", "0.10.0"]);
}

#[test]
fn two_failed_launches_return_the_previous_version() {
    let tmp = tempfile::tempdir().unwrap();
    let layout = prepare(tmp.path(), &["0.0.1", "0.0.2"]);
    layout.activate(&Version::parse("0.0.2").unwrap()).unwrap();
    let marker = LaunchMarker::new(tmp.path().join("state"));

    marker.mark().unwrap();
    assert_eq!(
        roll_back_if_needed(&layout, &marker),
        None,
        "первая попытка"
    );

    marker.mark().unwrap();
    let rolled = roll_back_if_needed(&layout, &marker).expect("вторая попытка откатывает");

    assert_eq!(rolled.to_string(), "0.0.1");
    assert_eq!(layout.current_version().unwrap().to_string(), "0.0.1");
}

#[test]
fn a_successful_launch_clears_the_marker() {
    let tmp = tempfile::tempdir().unwrap();
    let layout = prepare(tmp.path(), &["0.0.1", "0.0.2"]);
    layout.activate(&Version::parse("0.0.2").unwrap()).unwrap();
    let marker = LaunchMarker::new(tmp.path().join("state"));

    marker.mark().unwrap();
    marker.clear().unwrap();
    marker.mark().unwrap();

    assert_eq!(
        roll_back_if_needed(&layout, &marker),
        None,
        "успешный старт обнулил счётчик"
    );
}

/// Откатываться некуда — не повод падать: приложение обязано пробовать
/// запуститься дальше.
#[test]
fn with_nothing_to_roll_back_to_the_marker_is_harmless() {
    let tmp = tempfile::tempdir().unwrap();
    let layout = prepare(tmp.path(), &["0.0.1"]);
    layout.activate(&Version::parse("0.0.1").unwrap()).unwrap();
    let marker = LaunchMarker::new(tmp.path().join("state"));

    marker.mark().unwrap();
    marker.mark().unwrap();

    assert_eq!(roll_back_if_needed(&layout, &marker), None);
    assert_eq!(layout.current_version().unwrap().to_string(), "0.0.1");
}
