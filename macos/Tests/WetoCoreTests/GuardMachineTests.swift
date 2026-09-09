import XCTest
@testable import WetoCore

final class GuardMachineTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let kz = GeoReading(ip: "203.0.113.177", primaryCountry: "KZ", confirmedCountry: "KZ", confirmSource: .freeipapi)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private let silence = GuardDecision.unproven(.geoUnavailable("таймаут запроса"))
    private let silentGeo = GeoOutcome.unavailable("таймаут запроса")

    private func protectedMachine() -> GuardMachine {
        var machine = GuardMachine(pauseCeiling: 60)
        _ = machine.apply(.verdict(.safe, geo: .resolved(kz)), at: t0)
        return machine
    }

    /// Единственный способ встать: плохой результат пробы.
    private func pausedMachine(at moment: TimeInterval = 0) -> GuardMachine {
        var machine = protectedMachine()
        _ = machine.apply(.verdict(silence, geo: silentGeo), at: at(moment))
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
        XCTAssertEqual(machine.pauseCeiling, Constants.pauseCeilingSeconds)
    }

    // MARK: - Вердикта нет: цели работают, пока не пришёл плохой результат

    // Холодный старт целей не трогает: проба спрашивается первой, отвечает она.
    // Принятая цена — до ~5 с работы без вердикта.
    func test_cold_start_leaves_the_targets_running() {
        var machine = GuardMachine(pauseCeiling: 60)
        XCTAssertEqual(machine.apply(.verdictLost(.coldStart), at: t0), .none)
        XCTAssertEqual(machine.phase, .verifying(cause: .coldStart))
        XCTAssertEqual(machine.phase.action, .run)
        XCTAssertNil(machine.remainingPause(at: at(600)), "в проверке считать нечего")
    }

    // Смена пути — тоже не повод останавливать цели.
    func test_a_path_change_leaves_the_targets_running() {
        var machine = protectedMachine()
        XCTAssertEqual(machine.apply(.verdictLost(.networkChanged), at: at(5)), .none)
        XCTAssertEqual(machine.phase, .verifying(cause: .networkChanged))
        XCTAssertEqual(machine.phase.action, .run)
    }

    func test_a_path_change_out_of_interference_leaves_the_targets_running() {
        var machine = protectedMachine()
        _ = machine.apply(.verdict(.safe, geo: .degraded(previous: kz, detail: "HTTP 429")), at: at(5))
        XCTAssertEqual(machine.apply(.verdictLost(.networkChanged), at: at(6)), .none)
        XCTAssertEqual(machine.phase, .verifying(cause: .networkChanged))
    }

    // Повторное «вердикта нет» — не новость, и такту в проверке считать нечего:
    // отсчёт до завершения появляется только вместе с паузой.
    func test_a_repeated_verdict_loss_changes_nothing_and_never_expires() {
        var machine = GuardMachine(pauseCeiling: 60)
        _ = machine.apply(.verdictLost(.coldStart), at: t0)
        XCTAssertEqual(machine.apply(.verdictLost(.coldStart), at: at(30)), .none)
        XCTAssertEqual(machine.phase, .verifying(cause: .coldStart))
        XCTAssertEqual(machine.apply(.verdictLost(.networkChanged), at: at(50)), .none)
        XCTAssertEqual(machine.phase, .verifying(cause: .networkChanged))
        XCTAssertEqual(machine.apply(.tick, at: at(3_600)), .none, "без результата пауза не начинается")
        XCTAssertEqual(machine.phase, .verifying(cause: .networkChanged))
    }

    // MARK: - Пауза начинается с плохого результата и только с него

    // Эпизод 19:31: молчат оба сервиса — первый же неответ ставит на паузу,
    // через 60 с завершение по потолку. Терпимости к молчанию больше нет.
    func test_the_first_silent_result_pauses_and_the_ceiling_terminates() {
        var machine = protectedMachine()

        XCTAssertEqual(machine.apply(.verdict(silence, geo: silentGeo), at: at(5)), .pause)
        XCTAssertEqual(machine.phase, .paused(since: at(5), reason: .geoUnavailable("таймаут запроса")))
        XCTAssertEqual(machine.phase.action, .pause)

        XCTAssertEqual(
            machine.apply(.verdict(silence, geo: silentGeo), at: at(10)),
            .none,
            "стоящему непроверенность ничего не добавляет"
        )
        XCTAssertEqual(machine.phase, .paused(since: at(5), reason: .geoUnavailable("таймаут запроса")))

        XCTAssertEqual(machine.apply(.tick, at: at(64)), .none, "потолок ещё не истёк")
        XCTAssertEqual(machine.remainingPause(at: at(64)), 1)
        XCTAssertEqual(machine.apply(.tick, at: at(65)), .terminate)
        XCTAssertEqual(machine.phase, .danger(.pauseExpired))
    }

    // Неответ в проверке — тот самый плохой результат: вот здесь цели и встают.
    func test_a_silent_result_in_verification_pauses() {
        var machine = GuardMachine(pauseCeiling: 60)
        _ = machine.apply(.verdictLost(.coldStart), at: t0)
        XCTAssertEqual(machine.apply(.verdict(.unproven(.confirmationUnavailable), geo: silentGeo), at: at(4)), .pause)
        XCTAssertEqual(machine.phase, .paused(since: at(4), reason: .confirmationUnavailable))
    }

    // Первая же проба непроверена, а вердикта не было: стоим, а не завершаем.
    func test_a_silent_result_from_disabled_pauses() {
        var machine = GuardMachine(pauseCeiling: 60)
        XCTAssertEqual(machine.apply(.verdict(.unproven(.confirmationUnavailable), geo: silentGeo), at: t0), .pause)
        XCTAssertEqual(machine.phase, .paused(since: t0, reason: .confirmationUnavailable))
    }

    // Помехи стоят на доказанном адресе, но неответ и их ставит на паузу.
    func test_a_silent_result_from_interference_pauses() {
        var machine = GuardMachine(phase: .interference(kz, reason: .geoUnavailable("HTTP 429")), pauseCeiling: 60)
        XCTAssertEqual(machine.apply(.verdict(silence, geo: silentGeo), at: at(5)), .pause)
        XCTAssertEqual(machine.phase, .paused(since: at(5), reason: .geoUnavailable("таймаут запроса")))
    }

    func test_a_changed_address_pauses_on_the_first_probe() {
        var machine = protectedMachine()
        let changed = GuardDecision.unproven(.addressChanged(observed: "198.51.100.7"))
        XCTAssertEqual(
            machine.apply(.verdict(changed, geo: .addressChanged(observed: "198.51.100.7", previous: kz)), at: at(5)),
            .pause
        )
        XCTAssertEqual(machine.phase, .paused(since: at(5), reason: .addressChanged(observed: "198.51.100.7")))
    }

    // Потолок считается от начала паузы, и продлить его нечем: «вердикта нет»
    // результатом не является, иначе минуту можно было бы тянуть сменами пути вечно.
    func test_a_path_change_while_paused_neither_resumes_nor_restarts_the_ceiling() {
        var machine = pausedMachine(at: 5)
        XCTAssertEqual(machine.apply(.verdictLost(.networkChanged), at: at(20)), .none)
        XCTAssertEqual(machine.phase, .paused(since: at(5), reason: .geoUnavailable("таймаут запроса")))
        XCTAssertEqual(machine.remainingPause(at: at(20)), 45)
        XCTAssertEqual(machine.apply(.tick, at: at(65)), .terminate)
        XCTAssertEqual(machine.phase, .danger(.pauseExpired))
    }

    // MARK: - Выход из паузы: safe возвращает, доказательство завершает

    func test_a_safe_verdict_resumes_the_targets() {
        var machine = pausedMachine(at: 5)
        XCTAssertEqual(machine.apply(.verdict(.safe, geo: .resolved(kz)), at: at(10)), .resume)
        XCTAssertEqual(machine.phase, .protected(kz))
    }

    // Доказанно тот же адрес — тоже ответ: цели возвращаются, но зелёный тут врал бы.
    func test_a_degraded_safe_verdict_resumes_into_interference() {
        var machine = pausedMachine(at: 5)
        XCTAssertEqual(
            machine.apply(.verdict(.safe, geo: .degraded(previous: kz, detail: "HTTP 429")), at: at(10)),
            .resume
        )
        XCTAssertEqual(machine.phase, .interference(kz, reason: .geoUnavailable("HTTP 429")))
        XCTAssertEqual(machine.phase.action, .run)
    }

    func test_evidence_terminates_from_pause() {
        var machine = pausedMachine(at: 5)
        XCTAssertEqual(machine.apply(.evidence(.vpnAppNotRunning), at: at(6)), .terminate)
        XCTAssertEqual(machine.phase, .danger(.vpnAppNotRunning))
    }

    // safe без чтения (охрана выключена или целей нет — политика отвечает safe до гео)
    // не выдаётся за проверенный выход: цели, поставленные на паузу, так не возобновляются.
    func test_safe_without_a_reading_does_not_resume_a_pause() {
        var machine = pausedMachine(at: 5)
        XCTAssertEqual(machine.apply(.verdict(.safe, geo: silentGeo), at: at(10)), .none)
        XCTAssertEqual(machine.phase, .paused(since: at(5), reason: .geoUnavailable("таймаут запроса")))
    }

    func test_safe_without_a_reading_keeps_a_protected_phase() {
        var machine = protectedMachine()
        XCTAssertEqual(machine.apply(.verdict(.safe, geo: silentGeo), at: at(5)), .none)
        XCTAssertEqual(machine.phase, .protected(kz))
    }

    func test_safe_without_a_reading_keeps_a_verification() {
        var machine = GuardMachine(pauseCeiling: 60)
        _ = machine.apply(.verdictLost(.coldStart), at: t0)
        XCTAssertEqual(machine.apply(.verdict(.safe, geo: silentGeo), at: at(2)), .none)
        XCTAssertEqual(machine.phase, .verifying(cause: .coldStart))
    }

    // MARK: - Доказательство завершает и держится до ответа пробы

    func test_evidence_terminates_from_a_running_phase() {
        var machine = protectedMachine()
        XCTAssertEqual(machine.apply(.evidence(.vpnAppNotRunning), at: at(1)), .terminate)
        XCTAssertEqual(machine.phase, .danger(.vpnAppNotRunning))
        XCTAssertEqual(machine.phase.action, .terminate)
    }

    func test_blocked_country_terminates_from_protected() {
        var machine = protectedMachine()
        let ru = GeoReading(ip: "5.5.5.5", primaryCountry: "RU", confirmedCountry: "RU", confirmSource: .freeipapi)
        XCTAssertEqual(
            machine.apply(.verdict(.kill(.blockedCountry(code: "RU", source: "ipinfo")), geo: .resolved(ru)), at: at(5)),
            .terminate
        )
        XCTAssertEqual(machine.phase, .danger(.blockedCountry(code: "RU", source: "ipinfo")))
    }

    // Ни одна причина несвежести из «Опасно» не выпускает: прежде «Проверка» была
    // стоящей фазой и переход туда был послаблением, теперь он разрешал бы запуск
    // целей без единой улики в пользу этого.
    func test_no_staleness_cause_lifts_a_danger() {
        for cause in [
            VerdictStaleness.Cause.coldStart, .configurationChanged, .networkChanged, .configurationAndNetworkChanged
        ] {
            var machine = dangerMachine()
            XCTAssertEqual(machine.apply(.verdictLost(cause), at: at(2)), .none, "\(cause)")
            XCTAssertEqual(machine.phase, .danger(.vpnAppNotRunning), "\(cause)")
            XCTAssertEqual(machine.phase.action, .terminate, "\(cause)")
        }
    }

    // Опасно → safe по пробе: На страже, возобновлять нечего.
    func test_safe_after_danger_returns_to_protected_without_resume() {
        var machine = dangerMachine()
        XCTAssertEqual(machine.apply(.verdict(.safe, geo: .resolved(kz)), at: at(2)), .none)
        XCTAssertEqual(machine.phase, .protected(kz))
    }

    func test_unproven_adds_nothing_to_a_danger() {
        var machine = dangerMachine()
        XCTAssertEqual(machine.apply(.verdict(silence, geo: silentGeo), at: at(2)), .none)
        XCTAssertEqual(machine.phase, .danger(.vpnAppNotRunning))
    }

    // MARK: - Переоценка по установленному чтению

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
        XCTAssertEqual(machine.phase, .danger(.blockedCountry(code: "KZ", source: "ipinfo")))
    }

    func test_reassessment_lifts_a_danger_it_can_refute() {
        var machine = dangerMachine()
        XCTAssertEqual(machine.apply(.reassessment(.safe, reading: kz), at: at(2)), .none)
        XCTAssertEqual(machine.phase, .protected(kz))
    }

    func test_reassessment_cannot_lift_an_expired_pause() {
        var machine = pausedMachine(at: 5)
        _ = machine.apply(.tick, at: at(70))
        XCTAssertEqual(machine.phase, .danger(.pauseExpired))
        XCTAssertEqual(machine.apply(.reassessment(.safe, reading: kz), at: at(71)), .none)
        XCTAssertEqual(machine.phase, .danger(.pauseExpired))
    }

    // Паузу снимает ответ пробы, а не пересчёт по прошлому чтению.
    func test_reassessment_does_not_resume_a_pause() {
        var machine = pausedMachine(at: 5)
        XCTAssertEqual(machine.apply(.reassessment(.safe, reading: kz), at: at(6)), .none)
        XCTAssertEqual(machine.phase, .paused(since: at(5), reason: .geoUnavailable("таймаут запроса")))
    }

    // Цель добавлена при выключенной охране и действующем чтении: сразу На страже.
    func test_reassessment_from_disabled_behaves_like_a_verdict() {
        var machine = GuardMachine(pauseCeiling: 60)
        XCTAssertEqual(machine.apply(.reassessment(.safe, reading: kz), at: t0), .none)
        XCTAssertEqual(machine.phase, .protected(kz))
    }

    func test_reassessment_unproven_changes_nothing() {
        var machine = protectedMachine()
        XCTAssertEqual(machine.apply(.reassessment(.unproven(.confirmationUnavailable), reading: kz), at: at(1)), .none)
        XCTAssertEqual(machine.phase, .protected(kz))
    }

    // MARK: - Выключение охраны и такт

    func test_disarming_resumes_a_pause() {
        var machine = pausedMachine(at: 5)
        XCTAssertEqual(machine.apply(.disarmed, at: at(6)), .resume)
        XCTAssertEqual(machine.phase, .disabled)
    }

    func test_disarming_a_running_guard_touches_nothing() {
        var machine = protectedMachine()
        XCTAssertEqual(machine.apply(.disarmed, at: at(1)), .none)
        XCTAssertEqual(machine.phase, .disabled)

        var verifying = GuardMachine(pauseCeiling: 60)
        _ = verifying.apply(.verdictLost(.coldStart), at: t0)
        XCTAssertEqual(verifying.apply(.disarmed, at: at(1)), .none)
        XCTAssertEqual(verifying.phase, .disabled)
    }

    func test_disarming_after_a_termination_does_not_resume_anything() {
        var machine = dangerMachine()
        XCTAssertEqual(machine.apply(.disarmed, at: at(2)), .none)
        XCTAssertEqual(machine.phase, .disabled)
    }

    // Такт считает только потолок паузы: у нестоящих фаз ему нечего считать.
    func test_a_tick_does_nothing_while_targets_run_or_are_terminated() {
        var machine = protectedMachine()
        XCTAssertNil(machine.remainingPause(at: at(5)))
        XCTAssertEqual(machine.apply(.tick, at: at(5)), .none)
        XCTAssertEqual(machine.phase, .protected(kz))

        _ = machine.apply(.evidence(.vpnAppNotRunning), at: at(6))
        XCTAssertNil(machine.remainingPause(at: at(600)))
        XCTAssertEqual(machine.apply(.tick, at: at(600)), .none)
        XCTAssertEqual(machine.phase, .danger(.vpnAppNotRunning))

        var disabled = GuardMachine(pauseCeiling: 60)
        XCTAssertEqual(disabled.apply(.tick, at: at(600)), .none)
        XCTAssertEqual(disabled.phase, .disabled)
    }

    // MARK: - Оси спеки

    // Вторая ось спеки: действие над целями выводится из фазы однозначно,
    // и стоящая фаза ровно одна.
    func test_actions_are_derived_from_the_six_phases() {
        XCTAssertEqual(GuardPhase.disabled.action, .run)
        XCTAssertEqual(GuardPhase.verifying(cause: .coldStart).action, .run)
        XCTAssertEqual(GuardPhase.protected(kz).action, .run)
        XCTAssertEqual(GuardPhase.interference(kz, reason: .confirmationUnavailable).action, .run)
        XCTAssertEqual(GuardPhase.paused(since: t0, reason: .confirmationUnavailable).action, .pause)
        XCTAssertEqual(GuardPhase.danger(.pauseExpired).action, .terminate)
    }

    func test_only_running_phases_carry_a_reading_and_only_the_pause_a_moment() {
        XCTAssertEqual(GuardPhase.protected(kz).reading, kz)
        XCTAssertEqual(GuardPhase.interference(kz, reason: .confirmationUnavailable).reading, kz)
        XCTAssertNil(GuardPhase.disabled.reading)
        XCTAssertNil(GuardPhase.verifying(cause: .coldStart).reading)
        XCTAssertNil(GuardPhase.paused(since: t0, reason: .confirmationUnavailable).reading)
        XCTAssertNil(GuardPhase.danger(.pauseExpired).reading)

        XCTAssertEqual(GuardPhase.paused(since: t0, reason: .confirmationUnavailable).pausedSince, t0)
        XCTAssertNil(GuardPhase.disabled.pausedSince)
        XCTAssertNil(GuardPhase.verifying(cause: .coldStart).pausedSince, "в проверке цели работают")
        XCTAssertNil(GuardPhase.protected(kz).pausedSince)
        XCTAssertNil(GuardPhase.interference(kz, reason: .confirmationUnavailable).pausedSince)
        XCTAssertNil(GuardPhase.danger(.pauseExpired).pausedSince)
    }

    // «На страже» у protected и interference — не опечатка: заголовок отвечает
    // «я защищён?», причина и цвет щита — отдельно (StatusPresentation, GuardVM.statusColor).
    func test_titles_are_the_six_states() {
        XCTAssertEqual(GuardPhase.disabled.title, "Охрана выключена")
        XCTAssertEqual(GuardPhase.verifying(cause: .coldStart).title, "Проверяю выход")
        XCTAssertEqual(GuardPhase.protected(kz).title, "На страже")
        XCTAssertEqual(GuardPhase.interference(kz, reason: .confirmationUnavailable).title, "На страже")
        XCTAssertEqual(GuardPhase.paused(since: t0, reason: .confirmationUnavailable).title, "Выход не подтверждён")
        XCTAssertEqual(GuardPhase.danger(.pauseExpired).title, "Небезопасно")
    }
}
