//! История возврата цели в терминал. Порт `macos/Tests/WetoCoreTests/TerminalReturnTrackerTests.swift`.

use std::collections::HashSet;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use weto_core::terminal_return::{
    TerminalReturnState, TerminalReturnTracker, OFFER_WINDOW, VERIFY_WINDOW,
};

fn at(seconds: u64) -> SystemTime {
    UNIX_EPOCH + Duration::from_secs(1_000 + seconds)
}

fn waiting(pids: &[i32]) -> HashSet<i32> {
    pids.iter().copied().collect()
}

/// Цель, потерявшая передний план при снятии паузы, возвращается сама и один раз:
/// второй ввод `fg` в шелл уже никому не нужен.
#[test]
fn a_target_left_in_the_background_gets_one_automatic_attempt() {
    let mut tracker = TerminalReturnTracker::default();

    assert_eq!(tracker.observe(&waiting(&[200]), at(0)).attempts, vec![200]);
    assert_eq!(tracker.state(200), Some(TerminalReturnState::Returning));
    assert!(tracker.observe(&waiting(&[200]), at(1)).attempts.is_empty());
}

/// Команда ушла — это ещё не возврат. Решает наблюдение: цель снова впереди.
#[test]
fn coming_back_to_the_foreground_ends_the_story() {
    let mut tracker = TerminalReturnTracker::default();
    tracker.observe(&waiting(&[200]), at(0));
    tracker.finished(200, true, at(0));

    tracker.observe(&waiting(&[]), at(1));

    assert_eq!(tracker.state(200), None);
}

/// Автоматика не смогла — кнопка. Она и есть запасной путь.
#[test]
fn a_failed_automatic_attempt_offers_the_button() {
    let mut tracker = TerminalReturnTracker::default();
    tracker.observe(&waiting(&[200]), at(0));

    tracker.finished(200, false, at(0));

    assert_eq!(tracker.state(200), Some(TerminalReturnState::Offered));
}

/// Команда прошла, а цель так и не вернулась: например, `fg` достался другому заданию.
#[test]
fn a_command_that_changed_nothing_offers_the_button_too() {
    let mut tracker = TerminalReturnTracker::default();
    tracker.observe(&waiting(&[200]), at(0));
    tracker.finished(200, true, at(0));

    tracker.observe(
        &waiting(&[200]),
        at(0) + VERIFY_WINDOW - Duration::from_secs(1),
    );
    assert_eq!(tracker.state(200), Some(TerminalReturnState::Returning));

    tracker.observe(&waiting(&[200]), at(0) + VERIFY_WINDOW);
    assert_eq!(tracker.state(200), Some(TerminalReturnState::Offered));
}

/// Кнопка, показанная на третьей секунде, живёт не дольше остальных: отсчёт от снятия паузы.
#[test]
fn the_five_minutes_run_from_the_lift_not_from_being_shown() {
    let mut tracker = TerminalReturnTracker::default();
    tracker.observe(&waiting(&[200]), at(0));
    tracker.finished(200, true, at(0));
    tracker.observe(&waiting(&[200]), at(0) + VERIFY_WINDOW);
    assert_eq!(tracker.state(200), Some(TerminalReturnState::Offered));

    tracker.observe(
        &waiting(&[200]),
        at(0) + OFFER_WINDOW - Duration::from_secs(1),
    );
    assert_eq!(tracker.state(200), Some(TerminalReturnState::Offered));

    tracker.observe(&waiting(&[200]), at(0) + OFFER_WINDOW);
    assert_eq!(tracker.state(200), Some(TerminalReturnState::Expired));
}

/// Кнопка живёт максимум пять минут — от снятия паузы, а не от показа.
#[test]
fn the_button_goes_away_after_five_minutes() {
    let mut tracker = TerminalReturnTracker::default();
    tracker.observe(&waiting(&[200]), at(0));
    tracker.finished(200, false, at(0));

    tracker.observe(
        &waiting(&[200]),
        at(0) + OFFER_WINDOW - Duration::from_secs(1),
    );
    assert_eq!(tracker.state(200), Some(TerminalReturnState::Offered));

    tracker.observe(&waiting(&[200]), at(0) + OFFER_WINDOW);
    assert_eq!(tracker.state(200), Some(TerminalReturnState::Expired));
}

/// Нажатие — вторая и последняя попытка: не вышло, остаётся подсказка.
#[test]
fn a_press_that_fails_leaves_the_hint_and_no_button() {
    let mut tracker = TerminalReturnTracker::default();
    tracker.observe(&waiting(&[200]), at(0));
    tracker.finished(200, false, at(0));

    assert!(tracker.press(200));
    assert_eq!(tracker.state(200), Some(TerminalReturnState::Returning));
    assert!(!tracker.press(200), "до первого нажатия — и не больше");

    tracker.finished(200, false, at(5));
    assert_eq!(tracker.state(200), Some(TerminalReturnState::Failed));
}

/// Нажатие прошло, но цель не вернулась за отведённое время — тоже подсказка,
/// и про этот переход узнаёт вызывающий: ему поднимать окно терминала.
#[test]
fn a_press_that_changed_nothing_reports_the_failure_once() {
    let mut tracker = TerminalReturnTracker::default();
    tracker.observe(&waiting(&[200]), at(0));
    tracker.finished(200, false, at(0));
    tracker.press(200);
    tracker.finished(200, true, at(5));

    let step = tracker.observe(&waiting(&[200]), at(5) + VERIFY_WINDOW);
    assert_eq!(step.failed, vec![200]);
    assert_eq!(tracker.state(200), Some(TerminalReturnState::Failed));
    assert!(tracker.observe(&waiting(&[200]), at(30)).failed.is_empty());
}

/// Новая пауза начинает историю заново: снаружи она видна как «ждать нечего»,
/// потому что на паузе цели не возвращаются, а после неё снова положена попытка.
#[test]
fn a_new_pause_starts_over() {
    let mut tracker = TerminalReturnTracker::default();
    tracker.observe(&waiting(&[200]), at(0));
    tracker.finished(200, false, at(0));

    tracker.observe(&waiting(&[]), at(10));
    assert_eq!(
        tracker.observe(&waiting(&[200]), at(20)).attempts,
        vec![200]
    );
}

#[test]
fn nothing_to_press_for_an_unknown_target() {
    let mut tracker = TerminalReturnTracker::default();
    assert!(!tracker.press(200));
}
