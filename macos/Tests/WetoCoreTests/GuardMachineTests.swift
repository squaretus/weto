import XCTest
@testable import WetoCore

final class GuardMachineTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let kz = GeoReading(ip: "91.224.74.177", primaryCountry: "KZ", confirmedCountry: "KZ", confirmSource: .freeipapi)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func protectedMachine() -> GuardMachine {
        var machine = GuardMachine(tolerance: 2, pauseCeiling: 60)
        _ = machine.apply(.verdict(.safe, geo: .resolved(kz)), at: t0)
        return machine
    }

    private func dangerMachine() -> GuardMachine {
        var machine = protectedMachine()
        _ = machine.apply(.evidence(.vpnAppNotRunning), at: at(1))
        return machine
    }

    // Умолчания — не украшение конструктора: боевой код идёт именно через них,
    // а все тесты и фикстуры передают числа явно.
    func test_the_default_machine_carries_the_project_constants() {
        let machine = GuardMachine()
        XCTAssertEqual(machine.phase, .disabled)
        XCTAssertEqual(machine.tolerance, Constants.silenceToleranceProbes)
        XCTAssertEqual(machine.pauseCeiling, Constants.pauseCeilingSeconds)
    }

    // Холодный старт: вердикта нет — пауза, не завершение.
    func test_cold_start_pauses_until_the_verdict() {
        var machine = GuardMachine(tolerance: 2, pauseCeiling: 60)
        XCTAssertEqual(machine.apply(.verdictLost(.coldStart), at: t0), .pause)
        XCTAssertEqual(machine.phase, .verifying(since: t0, cause: .coldStart))
        XCTAssertEqual(machine.phase.action, .pause)
    }

    // Эпизод 18:03: safe через две секунды — цели возобновляются.
    func test_safe_verdict_resumes_a_verifying_pause() {
        var machine = GuardMachine(tolerance: 2, pauseCeiling: 60)
        _ = machine.apply(.verdictLost(.coldStart), at: t0)
        XCTAssertEqual(machine.apply(.verdict(.safe, geo: .resolved(kz)), at: at(2)), .resume)
        XCTAssertEqual(machine.phase, .protected(kz))
    }

    // Эпизод 19:31: две неудачные пробы терпим, третья — пауза, через 60 с — завершение.
    func test_silence_is_tolerated_then_paused_then_terminated_at_the_ceiling() {
        var machine = protectedMachine()
        let silence = GuardDecision.unproven(.geoUnavailable("таймаут запроса"))

        XCTAssertEqual(machine.apply(.verdict(silence, geo: .unavailable("таймаут запроса")), at: at(5)), .none)
        XCTAssertEqual(machine.phase, .interference(kz, reason: .geoUnavailable("таймаут запроса"), failures: 1))
        XCTAssertEqual(machine.phase.action, .run)

        XCTAssertEqual(
            machine.apply(.verdict(silence, geo: .unavailable("таймаут запроса")), at: at(10)),
            .none,
            "вторая неудача — ещё терпимость"
        )
        XCTAssertEqual(machine.phase, .interference(kz, reason: .geoUnavailable("таймаут запроса"), failures: 2))
        XCTAssertEqual(machine.phase.action, .run)

        XCTAssertEqual(machine.apply(.verdict(silence, geo: .unavailable("таймаут запроса")), at: at(15)), .pause)
        XCTAssertEqual(machine.phase, .paused(since: at(15), reason: .geoUnavailable("таймаут запроса")))

        XCTAssertEqual(machine.apply(.tick, at: at(74)), .none, "потолок ещё не истёк")
        XCTAssertEqual(machine.remainingPause(at: at(74)), 1)
        XCTAssertEqual(machine.apply(.tick, at: at(75)), .terminate)
        XCTAssertEqual(machine.phase, .danger(.pauseExpired))
    }

    // Терпимость — это N терпимых проб, а не N−1: с единицей терпится ровно одна.
    func test_the_tolerance_counts_the_probes_it_lets_pass() {
        var machine = GuardMachine(phase: .protected(kz), tolerance: 1, pauseCeiling: 60)
        let silence = GuardDecision.unproven(.geoUnavailable("таймаут"))

        XCTAssertEqual(machine.apply(.verdict(silence, geo: .unavailable("таймаут")), at: at(5)), .none)
        XCTAssertEqual(machine.phase, .interference(kz, reason: .geoUnavailable("таймаут"), failures: 1))
        XCTAssertEqual(machine.apply(.verdict(silence, geo: .unavailable("таймаут")), at: at(10)), .pause)
        XCTAssertEqual(machine.phase, .paused(since: at(10), reason: .geoUnavailable("таймаут")))
    }

    func test_safe_verdict_resets_the_tolerance_counter() {
        var machine = protectedMachine()
        let silence = GuardDecision.unproven(.geoUnavailable("таймаут"))
        _ = machine.apply(.verdict(silence, geo: .unavailable("таймаут")), at: at(5))
        _ = machine.apply(.verdict(.safe, geo: .resolved(kz)), at: at(10))
        XCTAssertEqual(machine.apply(.verdict(silence, geo: .unavailable("таймаут")), at: at(15)), .none)
        XCTAssertEqual(machine.phase, .interference(kz, reason: .geoUnavailable("таймаут"), failures: 1))
    }

    // Совпавший адрес от резервного сервиса — Помехи без счёта: доказательство, не давность.
    func test_degraded_safe_is_interference_with_zero_failures() {
        var machine = protectedMachine()
        XCTAssertEqual(machine.apply(.verdict(.safe, geo: .degraded(previous: kz, detail: "таймаут")), at: at(5)), .none)
        XCTAssertEqual(machine.phase, .interference(kz, reason: .geoUnavailable("таймаут"), failures: 0))
    }

    func test_changed_address_gets_no_tolerance() {
        var machine = protectedMachine()
        let changed = GuardDecision.unproven(.addressChanged(observed: "198.51.100.7"))
        XCTAssertEqual(
            machine.apply(.verdict(changed, geo: .addressChanged(observed: "198.51.100.7", previous: kz)), at: at(5)),
            .pause
        )
    }

    // Смена пути — пауза сразу из любого состояния, включая Помехи.
    func test_fingerprint_change_pauses_immediately() {
        var machine = protectedMachine()
        XCTAssertEqual(machine.apply(.verdictLost(.networkChanged), at: at(5)), .pause)
        XCTAssertEqual(machine.phase, .verifying(since: at(5), cause: .networkChanged))
    }

    func test_a_repeated_verdict_loss_does_not_restart_the_ceiling() {
        var machine = GuardMachine(tolerance: 2, pauseCeiling: 60)
        _ = machine.apply(.verdictLost(.coldStart), at: t0)
        XCTAssertEqual(machine.apply(.verdictLost(.coldStart), at: at(30)), .none)
        XCTAssertEqual(machine.phase.pausedSince, t0)

        // Пока вердикт несвеж, такт объявляет fail-closed каждую секунду: перезапуск
        // на каждом объявлении значил бы, что потолок не срабатывает никогда.
        XCTAssertEqual(machine.apply(.verdictLost(.coldStart), at: at(59)), .none)
        XCTAssertEqual(machine.phase.pausedSince, t0)
        XCTAssertEqual(machine.apply(.tick, at: at(60)), .terminate)
        XCTAssertEqual(machine.phase, .danger(.pauseExpired))
    }

    // Путь сменился уже в проверке: причина другая, и у нового пути свой отсчёт —
    // иначе он доедал бы минуту, начатую по прежней причине.
    func test_a_different_cause_restarts_the_verification_countdown() {
        var machine = GuardMachine(tolerance: 2, pauseCeiling: 60)
        _ = machine.apply(.verdictLost(.coldStart), at: t0)

        XCTAssertEqual(machine.apply(.verdictLost(.networkChanged), at: at(50)), .none, "цели уже стоят")
        XCTAssertEqual(machine.phase, .verifying(since: at(50), cause: .networkChanged))
        XCTAssertEqual(machine.apply(.tick, at: at(100)), .none, "отсчёт идёт от смены пути")
        XCTAssertEqual(machine.remainingPause(at: at(100)), 10)
        XCTAssertEqual(machine.apply(.tick, at: at(110)), .terminate)
        XCTAssertEqual(machine.phase, .danger(.pauseExpired))
    }

    // Истёкшая пауза без установленного вердикта: каждый такт «вердикта нет» — и это не новость.
    func test_cold_start_loss_after_an_expired_pause_keeps_the_danger() {
        var machine = GuardMachine(tolerance: 2, pauseCeiling: 60)
        _ = machine.apply(.verdictLost(.coldStart), at: t0)
        _ = machine.apply(.tick, at: at(60))
        XCTAssertEqual(machine.phase, .danger(.pauseExpired))
        XCTAssertEqual(machine.apply(.verdictLost(.coldStart), at: at(61)), .none)
        XCTAssertEqual(machine.phase, .danger(.pauseExpired))
    }

    // А смена пути из «Опасно» — новая проверка: у нового пути свой шанс.
    func test_network_change_after_danger_starts_a_new_verification() {
        var machine = dangerMachine()
        XCTAssertEqual(machine.apply(.verdictLost(.networkChanged), at: at(2)), .pause)
        XCTAssertEqual(machine.phase, .verifying(since: at(2), cause: .networkChanged))
    }

    // п. 11: правка настроек вердикт не обесценивает — в том числе доказанное «Опасно».
    // Иначе одна правка снимала бы завершение, и цель, запущенная в это окно,
    // всего лишь встала бы на паузу.
    func test_a_settings_edit_does_not_lift_a_danger() {
        var machine = dangerMachine()
        XCTAssertEqual(machine.apply(.verdictLost(.configurationChanged), at: at(2)), .none)
        XCTAssertEqual(machine.phase, .danger(.vpnAppNotRunning))
        XCTAssertEqual(machine.phase.action, .terminate)
    }

    // Все четыре причины несвежести из «Опасно»: выпускает только та, что меняет путь.
    func test_only_a_path_change_lifts_a_danger_into_a_new_verification() {
        for cause in [VerdictStaleness.Cause.networkChanged, .configurationAndNetworkChanged] {
            var machine = dangerMachine()
            XCTAssertEqual(machine.apply(.verdictLost(cause), at: at(2)), .pause, "\(cause)")
            XCTAssertEqual(machine.phase, .verifying(since: at(2), cause: cause), "\(cause)")
        }
        for cause in [VerdictStaleness.Cause.coldStart, .configurationChanged] {
            var machine = dangerMachine()
            XCTAssertEqual(machine.apply(.verdictLost(cause), at: at(2)), .none, "\(cause)")
            XCTAssertEqual(machine.phase, .danger(.vpnAppNotRunning), "\(cause)")
        }
    }

    // Доказательство завершает из любого состояния.
    func test_evidence_terminates_from_pause() {
        var machine = GuardMachine(tolerance: 2, pauseCeiling: 60)
        _ = machine.apply(.verdictLost(.coldStart), at: t0)
        XCTAssertEqual(machine.apply(.evidence(.vpnAppNotRunning), at: at(1)), .terminate)
        XCTAssertEqual(machine.phase, .danger(.vpnAppNotRunning))
    }

    func test_blocked_country_terminates_from_protected() {
        var machine = protectedMachine()
        let ru = GeoReading(ip: "5.5.5.5", primaryCountry: "RU", confirmedCountry: "RU", confirmSource: .freeipapi)
        XCTAssertEqual(
            machine.apply(.verdict(.kill(.blockedCountry(code: "RU", source: "ipinfo")), geo: .resolved(ru)), at: at(5)),
            .terminate
        )
    }

    // Опасно → safe по пробе: На страже, возобновлять нечего.
    func test_safe_after_danger_returns_to_protected_without_resume() {
        var machine = protectedMachine()
        _ = machine.apply(.evidence(.vpnAppNotRunning), at: at(1))
        XCTAssertEqual(machine.apply(.verdict(.safe, geo: .resolved(kz)), at: at(2)), .none)
        XCTAssertEqual(machine.phase, .protected(kz))
    }

    // п. 11: правка настроек при действующем вердикте ничего не трогает.
    func test_reassessment_safe_keeps_running_targets_running() {
        var machine = protectedMachine()
        XCTAssertEqual(machine.apply(.reassessment(.safe, reading: kz), at: at(1)), .none)
        XCTAssertEqual(machine.phase, .protected(kz))
    }

    func test_reassessment_with_evidence_terminates() {
        var machine = protectedMachine()
        XCTAssertEqual(
            machine.apply(.reassessment(.kill(.blockedCountry(code: "KZ", source: "ipinfo")), reading: kz), at: at(1)),
            .terminate
        )
    }

    func test_reassessment_lifts_a_danger_it_can_refute() {
        var machine = protectedMachine()
        _ = machine.apply(.reassessment(.kill(.blockedCountry(code: "KZ", source: "ipinfo")), reading: kz), at: at(1))
        XCTAssertEqual(machine.apply(.reassessment(.safe, reading: kz), at: at(2)), .none)
        XCTAssertEqual(machine.phase, .protected(kz))
    }

    func test_reassessment_cannot_lift_an_expired_pause() {
        var machine = protectedMachine()
        _ = machine.apply(.verdict(.unproven(.geoUnavailable("т")), geo: .unavailable("т")), at: at(5))
        _ = machine.apply(.verdict(.unproven(.geoUnavailable("т")), geo: .unavailable("т")), at: at(10))
        _ = machine.apply(.verdict(.unproven(.geoUnavailable("т")), geo: .unavailable("т")), at: at(15))
        _ = machine.apply(.tick, at: at(80))
        XCTAssertEqual(machine.apply(.reassessment(.safe, reading: kz), at: at(71)), .none)
        XCTAssertEqual(machine.phase, .danger(.pauseExpired))
    }

    func test_reassessment_does_not_resume_a_pause() {
        var machine = GuardMachine(tolerance: 2, pauseCeiling: 60)
        _ = machine.apply(.verdictLost(.coldStart), at: t0)
        XCTAssertEqual(machine.apply(.reassessment(.safe, reading: kz), at: at(1)), .none)
        XCTAssertEqual(machine.phase.action, .pause)
    }

    // Цель добавлена при выключенной охране и действующем чтении: сразу На страже.
    func test_reassessment_from_disabled_behaves_like_a_verdict() {
        var machine = GuardMachine(tolerance: 2, pauseCeiling: 60)
        XCTAssertEqual(machine.apply(.reassessment(.safe, reading: kz), at: t0), .none)
        XCTAssertEqual(machine.phase, .protected(kz))
    }

    func test_disarming_resumes_a_pause() {
        var machine = GuardMachine(tolerance: 2, pauseCeiling: 60)
        _ = machine.apply(.verdictLost(.coldStart), at: t0)
        XCTAssertEqual(machine.apply(.disarmed, at: at(1)), .resume)
        XCTAssertEqual(machine.phase, .disabled)
    }

    // Смена пути, пока цели стоят: возобновлять нечего, но отсчёт идёт по новому пути.
    // Без сброса момента потолок доедал бы паузу, начатую по прежнему пути.
    func test_a_path_change_while_paused_restarts_the_countdown_without_a_second_pause() {
        var machine = protectedMachine()
        let silence = GuardDecision.unproven(.geoUnavailable("таймаут"))
        _ = machine.apply(.verdict(silence, geo: .unavailable("таймаут")), at: at(5))
        _ = machine.apply(.verdict(silence, geo: .unavailable("таймаут")), at: at(10))
        _ = machine.apply(.verdict(silence, geo: .unavailable("таймаут")), at: at(15))
        XCTAssertEqual(machine.phase.pausedSince, at(15))

        XCTAssertEqual(machine.apply(.verdictLost(.networkChanged), at: at(20)), .none, "цели уже стоят")
        XCTAssertEqual(machine.phase, .verifying(since: at(20), cause: .networkChanged))
        XCTAssertEqual(machine.apply(.tick, at: at(75)), .none, "отсчёт идёт от смены пути, а не от прежней паузы")
        XCTAssertEqual(machine.apply(.tick, at: at(80)), .terminate)
    }

    func test_a_path_change_pauses_out_of_interference_too() {
        var machine = protectedMachine()
        _ = machine.apply(.verdict(.unproven(.geoUnavailable("таймаут")), geo: .unavailable("таймаут")), at: at(5))
        XCTAssertEqual(machine.apply(.verdictLost(.networkChanged), at: at(6)), .pause)
        XCTAssertEqual(machine.phase, .verifying(since: at(6), cause: .networkChanged))
    }

    // Выключение охраны при работающих целях снимать нечего.
    func test_disarming_a_running_guard_touches_nothing() {
        var machine = protectedMachine()
        XCTAssertEqual(machine.apply(.disarmed, at: at(1)), .none)
        XCTAssertEqual(machine.phase, .disabled)
    }

    func test_disarming_after_a_termination_does_not_resume_anything() {
        var machine = protectedMachine()
        _ = machine.apply(.evidence(.vpnAppNotRunning), at: at(1))
        XCTAssertEqual(machine.apply(.disarmed, at: at(2)), .none)
        XCTAssertEqual(machine.phase, .disabled)
    }

    // Такт считает только потолок: у нестоящих фаз ему нечего считать.
    func test_a_tick_does_nothing_while_targets_run() {
        var machine = protectedMachine()
        XCTAssertNil(machine.remainingPause(at: at(5)))
        XCTAssertEqual(machine.apply(.tick, at: at(5)), .none)
        XCTAssertEqual(machine.phase, .protected(kz))

        _ = machine.apply(.evidence(.vpnAppNotRunning), at: at(6))
        XCTAssertNil(machine.remainingPause(at: at(600)))
        XCTAssertEqual(machine.apply(.tick, at: at(600)), .none)
        XCTAssertEqual(machine.phase, .danger(.vpnAppNotRunning))
    }

    // Первая же проба непроверена, а вердикта не было: стоим, а не завершаем.
    func test_unproven_from_disabled_starts_a_verification() {
        var machine = GuardMachine(tolerance: 2, pauseCeiling: 60)
        XCTAssertEqual(
            machine.apply(.verdict(.unproven(.confirmationUnavailable), geo: .unavailable("таймаут")), at: t0),
            .pause
        )
        XCTAssertEqual(machine.phase, .verifying(since: t0, cause: .coldStart))
    }

    // Непроверенность тому, кто уже стоит или уже завершён, ничего не добавляет:
    // потолок считает такт, и повторная проба его не перезапускает.
    func test_unproven_adds_nothing_to_a_verification() {
        var machine = GuardMachine(tolerance: 2, pauseCeiling: 60)
        _ = machine.apply(.verdictLost(.coldStart), at: t0)
        XCTAssertEqual(
            machine.apply(.verdict(.unproven(.geoUnavailable("таймаут")), geo: .unavailable("таймаут")), at: at(30)),
            .none
        )
        XCTAssertEqual(machine.phase, .verifying(since: t0, cause: .coldStart))
    }

    func test_unproven_adds_nothing_to_a_danger() {
        var machine = protectedMachine()
        _ = machine.apply(.evidence(.vpnAppNotRunning), at: at(1))
        XCTAssertEqual(
            machine.apply(.verdict(.unproven(.geoUnavailable("таймаут")), geo: .unavailable("таймаут")), at: at(2)),
            .none
        )
        XCTAssertEqual(machine.phase, .danger(.vpnAppNotRunning))
    }

    // safe без чтения (охрана выключена или целей нет — политика отвечает safe до гео)
    // не выдаётся за проверенный выход: цели, поставленные на паузу, так не возобновляются.
    func test_safe_without_a_reading_does_not_resume_a_pause() {
        var machine = GuardMachine(tolerance: 2, pauseCeiling: 60)
        _ = machine.apply(.verdictLost(.coldStart), at: t0)
        XCTAssertEqual(machine.apply(.verdict(.safe, geo: .unavailable("таймаут")), at: at(2)), .none)
        XCTAssertEqual(machine.phase, .verifying(since: t0, cause: .coldStart))
    }

    func test_safe_without_a_reading_keeps_a_protected_phase() {
        var machine = protectedMachine()
        XCTAssertEqual(machine.apply(.verdict(.safe, geo: .unavailable("таймаут")), at: at(5)), .none)
        XCTAssertEqual(machine.phase, .protected(kz))
    }

    // Переоценка счёт терпимости не ведёт: пробы не было, неудачи не было.
    func test_reassessment_unproven_changes_nothing() {
        var machine = protectedMachine()
        XCTAssertEqual(machine.apply(.reassessment(.unproven(.confirmationUnavailable), reading: kz), at: at(1)), .none)
        XCTAssertEqual(machine.phase, .protected(kz))
    }

    // Вторая ось спеки: действие над целями выводится из фазы однозначно.
    func test_actions_are_derived_from_the_six_phases() {
        XCTAssertEqual(GuardPhase.disabled.action, .run)
        XCTAssertEqual(GuardPhase.verifying(since: t0, cause: .coldStart).action, .pause)
        XCTAssertEqual(GuardPhase.protected(kz).action, .run)
        XCTAssertEqual(GuardPhase.interference(kz, reason: .confirmationUnavailable, failures: 1).action, .run)
        XCTAssertEqual(GuardPhase.paused(since: t0, reason: .confirmationUnavailable).action, .pause)
        XCTAssertEqual(GuardPhase.danger(.pauseExpired).action, .terminate)
    }

    func test_only_running_phases_carry_a_reading_and_only_standing_ones_a_moment() {
        XCTAssertEqual(GuardPhase.protected(kz).reading, kz)
        XCTAssertEqual(GuardPhase.interference(kz, reason: .confirmationUnavailable, failures: 2).reading, kz)
        XCTAssertNil(GuardPhase.disabled.reading)
        XCTAssertNil(GuardPhase.verifying(since: t0, cause: .coldStart).reading)
        XCTAssertNil(GuardPhase.paused(since: t0, reason: .confirmationUnavailable).reading)
        XCTAssertNil(GuardPhase.danger(.pauseExpired).reading)

        XCTAssertEqual(GuardPhase.verifying(since: t0, cause: .coldStart).pausedSince, t0)
        XCTAssertEqual(GuardPhase.paused(since: t0, reason: .confirmationUnavailable).pausedSince, t0)
        XCTAssertNil(GuardPhase.disabled.pausedSince)
        XCTAssertNil(GuardPhase.protected(kz).pausedSince)
        XCTAssertNil(GuardPhase.interference(kz, reason: .confirmationUnavailable, failures: 1).pausedSince)
        XCTAssertNil(GuardPhase.danger(.pauseExpired).pausedSince)
    }

    func test_titles_are_the_six_states() {
        XCTAssertEqual(GuardPhase.disabled.title, "Выключено")
        XCTAssertEqual(GuardPhase.verifying(since: t0, cause: .coldStart).title, "Проверка")
        XCTAssertEqual(GuardPhase.protected(kz).title, "На страже")
        XCTAssertEqual(GuardPhase.interference(kz, reason: .confirmationUnavailable, failures: 1).title, "Помехи")
        XCTAssertEqual(GuardPhase.paused(since: t0, reason: .confirmationUnavailable).title, "Пауза")
        XCTAssertEqual(GuardPhase.danger(.pauseExpired).title, "Опасно")
    }
}
