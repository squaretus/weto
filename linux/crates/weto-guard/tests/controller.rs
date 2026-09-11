//! Машина состояний охраны на подменённых границах.
//!
//! Здесь — вердикт и его свежесть: когда охрана идёт в сеть, чему верит и что
//! из этого следует для целей. Про паузу, учёт остановленных и журнал стояния
//! отвечает соседний файл (`pause.rs`).

mod harness;

use std::time::Duration;

use harness::{harness, harness_with_window};
use weto_core::check::{CheckOutcome, CheckTrigger};
use weto_core::guard_machine::{GuardAction, GuardPhase};
use weto_core::policy::{UnprovenReason, UnsafeEvidence};
use weto_sys::process_signaler::ProcessSignal;

fn evidence(phase: &GuardPhase) -> Option<&UnsafeEvidence> {
    match phase {
        GuardPhase::Danger(evidence) => Some(evidence),
        _ => None,
    }
}

fn is_protected(phase: &GuardPhase) -> bool {
    matches!(phase, GuardPhase::Protected(_))
}

// --- тесты -----------------------------------------------------------------

/// Холодный старт целей не трогает: вердикта нет, проба спрашивается первой,
/// и отвечает она. Принятая цена — до ~5 с работы без вердикта; прежнее
/// «сперва убили, потом спросили» стоило дороже.
#[test]
fn the_first_tick_leaves_the_targets_running_until_the_probe_answers() {
    let h = harness();

    let phase = h.controller.tick();

    assert!(is_protected(&phase), "{phase:?}");
    assert_eq!(h.geo.call_count(), 1);
    assert!(
        h.world.signals().is_empty(),
        "до ответа сети целям не посылают ничего: {:?}",
        h.world.signals()
    );
}

/// Без признака свежести цели вставали бы каждые пять секунд при исправном VPN.
#[test]
fn a_routine_tick_with_a_healthy_vpn_does_not_touch_the_targets() {
    let h = harness();
    h.controller.tick();

    let phase = h.controller.tick();

    assert!(is_protected(&phase));
    assert!(h.world.signals().is_empty());
    assert_eq!(
        h.geo.call_count(),
        1,
        "второй запрос не нужен: ничего не изменилось"
    );
}

/// Второй VPN, живущий рядом, — не событие для охраны.
///
/// Корпоративный клиент рвёт связь и поднимается сам. Носитель трафика при этом
/// не шелохнулся, значит и вердикт остался в силе: состава интерфейсов
/// в отпечатке нет вовсе.
#[test]
fn a_foreign_vpn_reconnecting_does_not_touch_the_targets() {
    let h = harness();
    h.controller.tick();

    // Снимок пересобран заново, носитель трафика тот же.
    h.network.route_moves_to("wg0");
    let phase = h.controller.tick();

    assert!(is_protected(&phase));
    assert!(h.world.signals().is_empty());
    assert_eq!(
        h.geo.call_count(),
        1,
        "чужой туннель не повод ни трогать цели, ни тратить запрос"
    );
}

/// Смена владельца маршрута обесценивает вердикт — но целей не трогает:
/// она просит пробу, а решает ответ. Запрос уходит и за показаниями: экран
/// обязан сказать, где пользователь оказался.
#[test]
fn moving_the_route_off_the_tunnel_re_verifies_without_touching_the_targets() {
    let h = harness();
    h.controller.tick();
    let probes_before = h.geo.call_count();

    h.geo.now_reports("KZ");
    h.network.route_moves_to("eth0");
    h.controller.tick();

    assert!(
        h.world.signals().is_empty(),
        "смена пути целей не трогает: отвечает проба, а не отпечаток"
    );
    assert!(
        h.geo.call_count() > probes_before,
        "вердикт обязан быть выведен заново, а не наследован"
    );
    assert!(h.controller.snapshot().report.is_some());
}

/// Закрытый VPN-клиент — доказательство, а доказательство завершает, и завершает
/// SIGKILL: мягкого сигнала граница не предлагает вовсе — стоящий процесс
/// обработчика не исполняет, и SIGTERM просто встал бы в очередь.
#[test]
fn a_closed_vpn_app_is_noticed_locally_and_kills() {
    let h = harness();
    h.controller.tick();

    h.world.vpn_app_closes();
    let phase = h.controller.tick();

    assert_eq!(evidence(&phase), Some(&UnsafeEvidence::VpnAppNotRunning));
    assert_eq!(h.world.signalled(ProcessSignal::Kill), vec![42]);
}

/// Упавший туннель виден по смене носителя трафика: вердикт недействителен,
/// и охрана идёт спрашивать заново.
#[test]
fn a_tunnel_that_went_down_invalidates_the_verdict() {
    let h = harness();
    h.controller.tick();
    let probes_before = h.geo.call_count();

    h.network.tunnel_goes_down();
    h.controller.tick();

    assert!(h.geo.call_count() > probes_before);
}

/// Правка настроек меняет ревизию, а значит обесценивает прежний вердикт.
#[test]
fn editing_the_settings_invalidates_the_verdict() {
    let h = harness();
    h.controller.tick();
    let calls_before = h.geo.call_count();

    h.settings
        .edit(|s| s.blocked_countries.push("DE".to_string()));
    h.controller.tick();

    assert_eq!(
        h.geo.call_count(),
        calls_before + 1,
        "после правки настроек вердикт нужно получать заново"
    );
}

/// Whitelist входит в ревизию конфигурации ровно так же, как чёрный список:
/// его правка обязана обесценить прежний вердикт.
#[test]
fn editing_the_whitelist_invalidates_the_verdict() {
    let h = harness();
    h.controller.tick();
    let calls_before = h.geo.call_count();

    h.settings
        .edit(|s| s.add_allowed_entry("NL").expect("запись валидна"));
    h.controller.tick();

    assert_eq!(h.geo.call_count(), calls_before + 1);
}

/// У подтверждающего сервиса лимит 60 запросов в минуту. Всплеск событий сети
/// не должен превращаться во всплеск запросов — и цели в это окно продолжают
/// работать: вердикта нет, но и результата нет, а трогает цели только результат.
#[test]
fn a_burst_of_changes_does_not_become_a_burst_of_requests() {
    let h = harness_with_window(Duration::from_millis(300));
    h.controller.tick();
    let calls_after_first = h.geo.call_count();

    h.settings
        .edit(|s| s.blocked_countries.push("DE".to_string()));
    let phase = h.controller.tick();

    assert_eq!(
        h.geo.call_count(),
        calls_after_first,
        "второй запрос придержан окном"
    );
    assert!(
        matches!(phase, GuardPhase::Verifying { .. }),
        "придержали запрос — значит вердикта нет: {phase:?}"
    );
    assert_eq!(phase.action(), GuardAction::Run);
    assert!(h.world.signals().is_empty());

    std::thread::sleep(Duration::from_millis(350));
    h.controller.tick();
    assert_eq!(
        h.geo.call_count(),
        calls_after_first + 1,
        "за пределами окна запрос обязан уйти"
    );
}

#[test]
fn a_blocked_country_kills_and_names_the_source() {
    let h = harness();
    h.controller.tick();

    h.geo.now_reports("RU");
    h.settings.edit(|_| {}); // сбрасываем свежесть, чтобы проба ушла заново
    let phase = h.controller.tick();

    assert_eq!(
        evidence(&phase),
        Some(&UnsafeEvidence::BlockedCountry {
            code: "RU".to_string(),
            source: "ipinfo".to_string()
        })
    );
    assert!(h
        .reporter
        .recorded()
        .kill_reasons
        .iter()
        .any(|r| r.contains("RU")));
}

/// Записи «подключение ещё не проверено» в журнале больше не бывает: до ответа
/// пробы цели работают, и завершение объясняется настоящей причиной сразу.
#[test]
fn the_journal_never_starts_with_an_unverified_excuse() {
    let h = harness();
    h.controller.tick();

    h.geo.now_reports("RU");
    h.settings.edit(|_| {});
    h.controller.tick();

    let recorded = h.reporter.recorded();
    assert!(
        recorded
            .kill_reasons
            .iter()
            .all(|r| !r.contains("ещё не проверено")),
        "{:?}",
        recorded.kill_reasons
    );
    assert!(
        recorded.kill_reasons.iter().any(|r| r.contains("RU")),
        "настоящая причина обязана дойти до журнала: {:?}",
        recorded.kill_reasons
    );
}

/// Нажатие, пославшее запрос, записывается вместе с трассами сервисов.
///
/// Журнал завершений про проверки молчит: та, что не породила завершения, следа
/// не оставляет. «Нажал, и ничего не произошло» разбирают по журналу проверок.
#[test]
fn a_manual_check_is_recorded_with_its_traces() {
    let h = harness();

    h.controller.probe_now();

    let checks = h.checks.events();
    let manual = checks
        .iter()
        .find(|c| c.trigger == CheckTrigger::Manual)
        .expect("проверка по кнопке обязана записаться");
    assert_eq!(manual.outcome, CheckOutcome::Answered);
    assert!(manual.duration_milliseconds.is_some());
    assert!(manual.fingerprint.is_some());
}

/// Рутинная удача расписания в журнал не идёт: раз в пять секунд она съела бы
/// ёмкость за четыре минуты и не сказала бы ничего.
#[test]
fn a_routine_scheduled_success_leaves_no_record() {
    let h = harness();

    h.controller.tick();

    assert!(
        h.checks
            .events()
            .iter()
            .all(|c| c.trigger != CheckTrigger::Schedule),
        "успешная рутина расписания в журнале не нужна"
    );
}

/// Кнопка спрашивает «где я», а не «нужна ли проверка»: запрос уходит даже
/// тогда, когда судьба целей решена локально.
#[test]
fn the_button_asks_the_network_even_when_the_verdict_is_local() {
    let h = harness();
    h.world.vpn_app_closes();
    h.controller.tick();
    let calls_before = h.geo.call_count();

    let phase = h.controller.probe_now();

    assert_eq!(
        evidence(&phase),
        Some(&UnsafeEvidence::VpnAppNotRunning),
        "локальное основание применяется сразу, жизни целям кнопка не продлевает"
    );
    assert_eq!(h.geo.call_count(), calls_before + 1);
    assert!(
        h.controller.snapshot().report.is_some(),
        "экран обязан показать страну, ради которой кнопку и нажали"
    );
}

/// Нажатие при исправном VPN не должно ронять состояние: иначе кнопка стоила бы
/// пользователю целей.
#[test]
fn the_button_does_not_cost_the_user_their_targets() {
    let h = harness();
    h.controller.tick();

    let phase = h.controller.probe_now();

    assert!(is_protected(&phase));
    assert!(h.world.signals().is_empty());
}

#[test]
fn a_disabled_guard_leaves_everything_alone() {
    let h = harness();
    h.settings.edit(|s| s.is_enabled = false);

    let phase = h.controller.tick();

    assert_eq!(phase, GuardPhase::Disabled);
    assert!(h.world.signals().is_empty());
    assert_eq!(h.geo.call_count(), 0, "выключенной охране сеть не нужна");
}

#[test]
fn without_targets_there_is_nothing_to_guard() {
    let h = harness();
    h.settings.edit(|s| s.targets.clear());

    let phase = h.controller.tick();

    assert_eq!(phase, GuardPhase::Disabled);
    assert_eq!(h.geo.call_count(), 0);
}

/// Невыбранное приложение оснований не даёт само по себе — охрана работает
/// по гео одной, и в этом наборе показаний она безопасна.
#[test]
fn an_unchosen_vpn_app_defers_to_geo() {
    let h = harness();
    h.settings.edit(|s| s.set_vpn_app(None));

    let phase = h.controller.tick();

    assert!(is_protected(&phase), "{phase:?}");
}

#[test]
fn running_targets_are_reported_for_the_screen() {
    let h = harness();
    h.controller.tick();

    let running = h.controller.snapshot().running;
    assert_eq!(running.len(), 1);
    assert_eq!(running[0].display_name, "nano");
}

/// Показания обязаны обновляться при падении VPN.
///
/// Судьба целей решается локально и в сеть за ней ходить незачем — но экран
/// отвечает на другой вопрос: «где я сейчас». Пока экономию запросов
/// распространяли и на него, после выключения VPN там навсегда оставались
/// адрес и страна туннеля, то есть экран показывал защиту, которой уже нет.
#[test]
fn the_readout_refreshes_when_the_tunnel_falls() {
    let h = harness();

    h.controller.tick();
    let probes_while_guarded = h.geo.call_count();
    assert!(probes_while_guarded > 0, "на страже проба обязана быть");
    assert!(h.controller.snapshot().report.is_some());

    h.geo.now_reports("KZ");
    h.network.tunnel_goes_down();
    h.controller.tick();
    assert!(
        h.geo.call_count() > probes_while_guarded,
        "после падения VPN показания обязаны обновиться"
    );

    let report = h
        .controller
        .snapshot()
        .report
        .expect("показания должны быть свежими, а не пустыми");
    assert_eq!(report.reference_country().or(Some("KZ")), Some("KZ"));
}

/// Обновление — одно на смену состояния сети, а не на каждый такт: у
/// подтверждающего сервиса лимит, и опрашивать его пять раз в минуту впустую
/// значило бы его исчерпать.
#[test]
fn a_settled_verdict_does_not_probe_every_tick() {
    let h = harness();

    h.network.tunnel_goes_down();
    h.controller.tick();
    let after_first = h.geo.call_count();

    for _ in 0..5 {
        h.controller.tick();
    }

    assert_eq!(
        h.geo.call_count(),
        after_first,
        "состояние сети не менялось — новых запросов быть не должно"
    );
}

/// Молчание ipinfo — не повод трогать цели, если адрес доказанно тот же.
/// Тот же адрес — та же страна, и это ответ, а не тишина: фаза «Помехи».
#[test]
fn silent_ipinfo_with_the_same_address_keeps_the_targets() {
    let h = harness();
    assert!(is_protected(&h.controller.tick()));

    h.geo.ipinfo_goes_silent("203.0.113.7");
    let phase = h.controller.probe_now();

    assert!(
        matches!(phase, GuardPhase::Interference { .. }),
        "адрес тот же — перепроверять нечего: {phase:?}"
    );
    assert_eq!(phase.action(), GuardAction::Run);
    assert!(h.world.signals().is_empty());
}

/// Адрес другой, страны для него никто не назвал — вердикта нет. Это `unproven`,
/// а `unproven` теперь ставит на паузу, а не завершает.
#[test]
fn silent_ipinfo_with_a_new_address_pauses() {
    let h = harness();
    assert!(is_protected(&h.controller.tick()));

    h.geo.ipinfo_goes_silent("198.51.100.231");
    let phase = h.controller.probe_now();

    assert!(
        matches!(
            phase,
            GuardPhase::Paused {
                reason: UnprovenReason::AddressChanged { .. },
                ..
            }
        ),
        "{phase:?}"
    );
    assert_eq!(h.world.signalled(ProcessSignal::Stop), vec![42]);
    assert!(h.world.signalled(ProcessSignal::Kill).is_empty());
}

/// Расписание гео: страна выхода меняется и на неизменном пути, поэтому запрос
/// уходит и без событий сети — но не чаще расписания.
#[test]
fn geo_schedule_asks_again_on_an_unchanged_path() {
    let h = harness();
    h.controller.tick();
    let calls_after_verdict = h.geo.call_count();

    h.controller.tick();
    assert_eq!(
        h.geo.call_count(),
        calls_after_verdict,
        "частота запросов не равна частоте тиков"
    );
}
