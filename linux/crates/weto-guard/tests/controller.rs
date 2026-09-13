//! Машина состояний охраны на подменённых границах.
//!
//! Здесь — вердикт и его свежесть: когда охрана идёт в сеть, чему верит и что
//! из этого следует для целей. Про паузу, учёт остановленных и журнал стояния
//! отвечает соседний файл (`pause.rs`).

mod harness;

use std::sync::Arc;
use std::time::Duration;

use harness::{detached, harness, harness_with_window, Harness};
use weto_core::check::{CheckOutcome, CheckTrigger};
use weto_core::guard_machine::{GuardAction, GuardPhase};
use weto_core::policy::{UnprovenReason, UnsafeEvidence};
use weto_sys::background::ThreadDispatcher;
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

/// Сколько обходов процессов стоил один проход охраны.
fn walks_in(h: &Harness, pass: impl FnOnce()) -> usize {
    let before = h.world.walks();
    pass();
    h.world.walks() - before
}

// --- тесты -----------------------------------------------------------------

/// Холодный старт целей не трогает: вердикта нет, проба спрашивается первой,
/// и отвечает она. Принятая цена — до ~5 с работы без вердикта; прежнее
/// «сперва убили, потом спросили» стоило дороже.
#[test]
fn the_first_tick_leaves_the_targets_running_until_the_probe_answers() {
    let h = harness();

    let phase = h.tick();

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
    h.tick();

    let phase = h.tick();

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
    h.tick();

    // Снимок пересобран заново, носитель трафика тот же.
    h.network.route_moves_to("wg0");
    let phase = h.tick();

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
    h.tick();
    let probes_before = h.geo.call_count();

    h.geo.now_reports("KZ");
    h.network.route_moves_to("eth0");
    h.tick();

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
    h.tick();

    h.world.vpn_app_closes();
    let phase = h.tick();

    assert_eq!(evidence(&phase), Some(&UnsafeEvidence::VpnAppNotRunning));
    assert_eq!(h.world.signalled(ProcessSignal::Kill), vec![42]);
}

/// Упавший туннель виден по смене носителя трафика: вердикт недействителен,
/// и охрана идёт спрашивать заново.
#[test]
fn a_tunnel_that_went_down_invalidates_the_verdict() {
    let h = harness();
    h.tick();
    let probes_before = h.geo.call_count();

    h.network.tunnel_goes_down();
    h.tick();

    assert!(h.geo.call_count() > probes_before);
}

/// Правка настроек меняет ревизию, а значит обесценивает прежний вердикт.
#[test]
fn editing_the_settings_invalidates_the_verdict() {
    let h = harness();
    h.tick();
    let calls_before = h.geo.call_count();

    h.settings
        .edit(|s| s.blocked_countries.push("DE".to_string()));
    h.tick();

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
    h.tick();
    let calls_before = h.geo.call_count();

    h.settings
        .edit(|s| s.add_allowed_entry("NL").expect("запись валидна"));
    h.tick();

    assert_eq!(h.geo.call_count(), calls_before + 1);
}

/// У подтверждающего сервиса лимит 60 запросов в минуту. Всплеск событий сети
/// не должен превращаться во всплеск запросов — и цели в это окно продолжают
/// работать: вердикта нет, но и результата нет, а трогает цели только результат.
#[test]
fn a_burst_of_changes_does_not_become_a_burst_of_requests() {
    let h = harness_with_window(Duration::from_millis(300));
    h.tick();
    let calls_after_first = h.geo.call_count();

    h.settings
        .edit(|s| s.blocked_countries.push("DE".to_string()));
    let phase = h.tick();

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
    h.tick();
    assert_eq!(
        h.geo.call_count(),
        calls_after_first + 1,
        "за пределами окна запрос обязан уйти"
    );
}

#[test]
fn a_blocked_country_kills_and_names_the_source() {
    let h = harness();
    h.tick();

    h.geo.now_reports("RU");
    h.settings.edit(|_| {}); // сбрасываем свежесть, чтобы проба ушла заново
    let phase = h.tick();

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
    h.tick();

    h.geo.now_reports("RU");
    h.settings.edit(|_| {});
    h.tick();

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

    h.probe_now();

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

    h.tick();

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
    h.tick();
    let calls_before = h.geo.call_count();

    let phase = h.probe_now();

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
    h.tick();

    let phase = h.probe_now();

    assert!(is_protected(&phase));
    assert!(h.world.signals().is_empty());
}

#[test]
fn a_disabled_guard_leaves_everything_alone() {
    let h = harness();
    h.settings.edit(|s| s.is_enabled = false);

    let phase = h.tick();

    assert_eq!(phase, GuardPhase::Disabled);
    assert!(h.world.signals().is_empty());
    assert_eq!(h.geo.call_count(), 0, "выключенной охране сеть не нужна");
}

#[test]
fn without_targets_there_is_nothing_to_guard() {
    let h = harness();
    h.settings.edit(|s| s.targets.clear());

    let phase = h.tick();

    assert_eq!(phase, GuardPhase::Disabled);
    assert_eq!(h.geo.call_count(), 0);
}

/// Невыбранное приложение оснований не даёт само по себе — охрана работает
/// по гео одной, и в этом наборе показаний она безопасна.
#[test]
fn an_unchosen_vpn_app_defers_to_geo() {
    let h = harness();
    h.settings.edit(|s| s.set_vpn_app(None));

    let phase = h.tick();

    assert!(is_protected(&phase), "{phase:?}");
}

#[test]
fn running_targets_are_reported_for_the_screen() {
    let h = harness();
    h.tick();

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

    h.tick();
    let probes_while_guarded = h.geo.call_count();
    assert!(probes_while_guarded > 0, "на страже проба обязана быть");
    assert!(h.controller.snapshot().report.is_some());

    h.geo.now_reports("KZ");
    h.network.tunnel_goes_down();
    h.tick();
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
    h.tick();
    let after_first = h.geo.call_count();

    for _ in 0..5 {
        h.tick();
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
    assert!(is_protected(&h.tick()));

    h.geo.ipinfo_goes_silent("203.0.113.7");
    let phase = h.probe_now();

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
    assert!(is_protected(&h.tick()));

    h.geo.ipinfo_goes_silent("198.51.100.231");
    let phase = h.probe_now();

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

// --- один обход на проход ----------------------------------------------------

/// Такт, отпустивший пробу, обходит процессы столько же раз, сколько молчаливый:
/// запроса он не ждёт, и лишнего обхода в нём нет.
///
/// Ответ приходит своим проходом — со своим входом редьюсеру и своим
/// применением. Это не «второй обход на такт», а второй проход: обход `/proc`
/// проект считает в миллисекундах, но два применения подряд внутри одного
/// прохода посылали бы сигналы по данным, которые первое уже изменило.
#[test]
fn a_tick_that_probes_walks_the_processes_once() {
    let h = harness();

    // Холодный старт: расписания гео ещё не было, значит проба уйдёт этим тактом.
    let probing = walks_in(&h, || {
        h.controller.tick();
    });
    assert_eq!(
        h.geo.call_count(),
        0,
        "проба ушла на свою дорожку, и запроса такт не ждёт"
    );
    assert_eq!(h.probes.pending(), 1, "она именно ушла, а не пропала");

    // Ответ: свой проход, своё применение.
    let answering = walks_in(&h, || {
        let phase = h.settle();
        assert!(is_protected(&phase), "{phase:?}");
    });
    assert_eq!(h.geo.call_count(), 1, "запрос состоялся ровно один");

    // Молчаливый такт: вердикт свеж, расписание не подошло — вход ровно один.
    let quiet = walks_in(&h, || {
        h.controller.tick();
    });
    assert_eq!(h.geo.call_count(), 1, "второго запроса тут быть не должно");

    assert_eq!(
        probing, quiet,
        "такт, отпустивший пробу, лишнего обхода не делает"
    );
    assert_eq!(answering, quiet, "и проход ответа — один проход, а не два");
    assert_eq!(
        h.reporter.recorded().finished,
        3,
        "по одному применению на проход, а не по два"
    );
}

/// Обход процессов у прохода ровно один — и у такта, и у прохода ответа.
///
/// Считается он на границе реестра, а не по намерению: пока статус
/// VPN-приложения и показания журнала ходили в `/proc` сами, такт стоил трёх
/// обходов. Дело не только в миллисекундах — второе чтение описывает другой
/// момент, и запись журнала объясняла бы завершение уликой из одного мгновения
/// и статусом приложения из другого.
#[test]
fn every_pass_reads_the_processes_exactly_once() {
    let h = harness();

    let cold = walks_in(&h, || {
        h.controller.tick();
    });
    assert_eq!(cold, 1, "холодный такт: один обход");

    let answering = walks_in(&h, || {
        let phase = h.settle();
        assert!(is_protected(&phase), "{phase:?}");
    });
    assert_eq!(answering, 1, "проход ответа: один обход");

    let quiet = walks_in(&h, || {
        h.controller.tick();
    });
    assert_eq!(quiet, 1, "молчаливый такт: один обход");

    // Закрытый VPN-клиент: локальное доказательство, завершение и запись журнала —
    // всё по одному и тому же снимку.
    h.world.vpn_app_closes();
    let killing = walks_in(&h, || {
        let phase = h.controller.tick();
        assert_eq!(evidence(&phase), Some(&UnsafeEvidence::VpnAppNotRunning));
    });
    assert_eq!(killing, 1, "такт с завершением: один обход");
    assert_eq!(h.world.signalled(ProcessSignal::Kill), vec![42]);

    // И под паузой, где обход самый горячий: план, сигналы, учёт и пилюли.
    h.world.vpn_app_returns();
    h.tick();
    h.geo.everything_goes_silent();
    let pausing = walks_in(&h, || {
        let phase = h.probe_now();
        assert_eq!(phase.action(), GuardAction::Pause, "{phase:?}");
    });
    assert_eq!(
        pausing, 2,
        "два прохода — два обхода: такт кнопки и проход её ответа"
    );
}

/// Возвращение VPN-приложения — тоже лишний вход, а не лишний обход.
///
/// Переоценка по установленному чтению идёт перед `Tick` тем же тактом,
/// и применение у них общее.
#[test]
fn a_reassessment_tick_walks_the_processes_once() {
    let h = harness();
    h.tick();

    h.world.vpn_app_closes();
    let closed = h.tick();
    assert_eq!(evidence(&closed), Some(&UnsafeEvidence::VpnAppNotRunning));

    h.world.vpn_app_returns();
    let reassessing = walks_in(&h, || {
        let phase = h.tick();
        assert!(is_protected(&phase), "{phase:?}");
    });
    let quiet = walks_in(&h, || {
        h.tick();
    });

    assert_eq!(
        h.geo.call_count(),
        1,
        "переоценка идёт по установленному чтению, без пробы"
    );
    assert_eq!(
        reassessing, quiet,
        "переоценка и такт — два входа редьюсеру и одно применение"
    );
}

/// Расписание гео: страна выхода меняется и на неизменном пути, поэтому запрос
/// уходит и без событий сети — но не чаще расписания.
#[test]
fn geo_schedule_asks_again_on_an_unchanged_path() {
    let h = harness();
    h.tick();
    let calls_after_verdict = h.geo.call_count();

    h.tick();
    assert_eq!(
        h.geo.call_count(),
        calls_after_verdict,
        "частота запросов не равна частоте тиков"
    );
}

// --- применение не ждёт пробы ------------------------------------------------

/// Стенд, у которого проба уходит в настоящий поток — как в приложении.
fn threaded() -> Harness {
    let mut h = harness();
    Arc::get_mut(&mut h.controller)
        .expect("дорожка выбирается до охраны")
        .set_probes(Box::new(ThreadDispatcher::named("тест-проба")));
    h
}

/// Цель, запущенная под «Опасно», завершается тем же проходом, а не после
/// ответа летящей пробы.
///
/// Расписание гео подходит раз в пять секунд, и запрос к ipinfo столько же
/// и висит на мёртвом канале. Пока проба шла внутри такта, всё это время цель,
/// запущенная под запретом, работала: поток охраны был занят ожиданием,
/// и применять решение было некому.
#[test]
fn a_target_born_under_danger_is_killed_without_waiting_for_the_answer() {
    let h = harness();
    h.tick();

    h.geo.now_reports("RU");
    let danger = h.probe_now();
    assert!(matches!(danger, GuardPhase::Danger(_)), "{danger:?}");
    assert_eq!(h.world.signalled(ProcessSignal::Kill), vec![42]);

    // Запрос ушёл и ответа ещё нет.
    h.controller.probe_now();
    assert_eq!(h.probes.pending(), 1, "проба в полёте");

    // Пользователь запустил цель заново, пока проба летит.
    h.world.add(detached(43, 1, "/usr/bin/nano"));
    let phase = h.controller.tick();

    assert_eq!(phase.action(), GuardAction::Terminate, "{phase:?}");
    assert_eq!(
        h.world.signalled(ProcessSignal::Kill),
        vec![42, 43],
        "запуск запрещён — и ждать ответа для этого не надо"
    );
    assert_eq!(
        h.probes.pending(),
        1,
        "летящую пробу такт не снимал и второй не начинал"
    );

    // А ответ, когда он придёт, применяется своим проходом.
    h.geo.now_reports("NL");
    let phase = h.settle();
    assert!(is_protected(&phase), "{phase:?}");
    assert_eq!(h.geo.call_count(), 3);
}

/// То же под паузой: новорождённая цель встаёт наравне с остальными, не дожидаясь
/// ответа, — а ответ, когда он придёт, снимает паузу со всех разом.
#[test]
fn a_target_born_under_the_pause_is_stopped_without_waiting_for_the_answer() {
    let h = harness();
    h.tick();

    h.geo.everything_goes_silent();
    let paused = h.probe_now();
    assert_eq!(paused.action(), GuardAction::Pause, "{paused:?}");
    assert_eq!(h.world.signalled(ProcessSignal::Stop), vec![42]);

    h.controller.probe_now();
    assert_eq!(h.probes.pending(), 1, "проба в полёте");

    h.world.add(detached(43, 1, "/usr/bin/nano"));
    let phase = h.controller.tick();

    assert_eq!(phase.action(), GuardAction::Pause, "{phase:?}");
    assert_eq!(
        h.world.signalled(ProcessSignal::Stop),
        vec![42, 43],
        "обязательство «вернуть из паузы» распространяется и на новорождённую"
    );
    assert!(h.world.is_stopped(43));

    h.geo.everything_answers_again();
    let phase = h.settle();
    assert!(is_protected(&phase), "{phase:?}");
    assert_eq!(h.world.signalled(ProcessSignal::Resume), vec![43, 42]);
}

/// Проба на настоящем потоке: пока запрос висит, проход идёт и применяет решение.
///
/// Тот же случай, что и выше, но дорожка здесь такая же, как в приложении:
/// если бы применение и запрос делили хоть один замок, такт встал бы тут намертво.
#[test]
fn a_pass_runs_while_the_request_hangs() {
    let h = threaded();
    h.controller.tick();
    h.controller.await_probe();

    h.geo.now_reports("RU");
    h.controller.probe_now();
    h.controller.await_probe();
    assert_eq!(h.world.signalled(ProcessSignal::Kill), vec![42]);

    // Запрос ушёл и висит — как ipinfo на мёртвом канале.
    h.geo.holds_the_request();
    h.controller.probe_now();
    h.geo.wait_until_asked();

    h.world.add(detached(43, 1, "/usr/bin/nano"));
    let phase = h.controller.tick();

    assert_eq!(phase.action(), GuardAction::Terminate, "{phase:?}");
    assert_eq!(
        h.world.signalled(ProcessSignal::Kill),
        vec![42, 43],
        "проход не ждёт ни запроса, ни его таймаута"
    );
    assert!(h.controller.is_probing(), "а запрос всё ещё в полёте");

    h.geo.answers();
    h.controller.await_probe();
    assert!(
        matches!(h.controller.phase(), GuardPhase::Danger(_)),
        "{:?}",
        h.controller.phase()
    );
}

/// Ответ пробы, начатой при прежних настройках, не применяется вовсе — но след
/// оставляет: запрос состоялся, и журнал проверок обязан назвать, почему
/// от ответа отказались.
#[test]
fn an_answer_that_outlived_its_settings_is_discarded_and_recorded() {
    let h = harness();
    h.tick();

    h.geo.now_reports("RU");
    h.controller.probe_now();
    // Пока проба летела, пользователь правил настройки.
    h.settings
        .edit(|s| s.blocked_countries.push("DE".to_string()));
    let phase = h.settle();

    assert!(
        h.world.signalled(ProcessSignal::Kill).is_empty(),
        "устаревший ответ целей не трогает: {phase:?}"
    );
    assert!(
        h.checks
            .events()
            .iter()
            .any(|c| c.outcome == CheckOutcome::DiscardedSettingsChanged),
        "{:?}",
        h.checks.events()
    );
}

/// Ответ пробы, начатой на прежнем пути, описывает уже не нас: путь сменился,
/// пока она летела.
#[test]
fn an_answer_that_outlived_its_path_is_discarded_and_recorded() {
    let h = harness();
    h.tick();

    h.geo.now_reports("RU");
    h.controller.probe_now();
    h.network.tunnel_goes_down();
    h.settle();

    assert!(
        h.world.signalled(ProcessSignal::Kill).is_empty(),
        "ответ про прежний путь не доказательство про этот"
    );
    assert!(
        h.checks
            .events()
            .iter()
            .any(|c| c.outcome == CheckOutcome::DiscardedPathChanged),
        "{:?}",
        h.checks.events()
    );
}

/// Нажатие в полёте запроса второго не порождает — и записывается: ровно это
/// и означает «нажал пять раз, а ничего не поехало». Автоматические поводы
/// приходят каждый такт, и их пропуски в журнале не нужны: полусотни записей
/// не хватило бы и на минуту.
#[test]
fn only_the_button_records_a_skipped_probe() {
    let h = harness();
    h.controller.tick();
    assert_eq!(h.probes.pending(), 1);

    h.controller.tick();
    h.controller.probe_now();

    assert_eq!(h.probes.pending(), 1, "запрос в полёте остался один");
    let skips: Vec<CheckTrigger> = h
        .checks
        .events()
        .iter()
        .filter(|c| c.outcome == CheckOutcome::SkippedProbeInFlight)
        .map(|c| c.trigger)
        .collect();
    assert_eq!(skips, vec![CheckTrigger::Manual], "{skips:?}");
}
