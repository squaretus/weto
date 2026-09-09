import XCTest
@testable import WetoShared
import WetoCore

final class StatusPresentationTests: XCTestCase {

    private let reading = GeoReading(
        ip: "203.0.113.28",
        primaryCountry: "KZ",
        confirmedCountry: "KZ",
        confirmSource: .freeipapi
    )

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private var allReasons: [UnprovenReason] {
        [.geoUnavailable("таймаут запроса"), .addressChanged(observed: "198.51.100.7"), .confirmationUnavailable]
    }

    private var allEvidence: [UnsafeEvidence] {
        [.vpnAppNotRunning, .blacklistedIP("203.0.113.28"), .blockedCountry(code: "RU", source: "ipinfo"),
         .countryConflict(primary: "KZ", confirmed: "DE"), .notWhitelistedIP("203.0.113.28"),
         .notWhitelistedCountry("KZ"), .pauseExpired]
    }

    /// Заголовок статуса — это состояние охраны, а не причина: шесть слов из `GuardPhase`,
    /// одинаковых на обеих платформах. Своего заголовка у представления больше нет.
    func test_phase_titles_are_the_six_canonical_words() {
        XCTAssertEqual(GuardPhase.disabled.title, "Выключено")
        XCTAssertEqual(GuardPhase.verifying(since: t0, cause: .coldStart).title, "Проверка")
        XCTAssertEqual(GuardPhase.protected(reading).title, "Защищено")
        XCTAssertEqual(
            GuardPhase.interference(reading, reason: .confirmationUnavailable, failures: 1).title,
            "Помехи"
        )
        XCTAssertEqual(GuardPhase.paused(since: t0, reason: .confirmationUnavailable).title, "Пауза")
        XCTAssertEqual(GuardPhase.danger(.pauseExpired).title, "Опасно")
    }

    // MARK: - Объяснение тремя строками (что сделано, почему, что дальше)

    /// Таблица «состояние × причина» без пустых клеток: каждая фаза с каждой уликой даёт три непустые строки.
    func test_every_phase_and_reason_combination_has_three_lines() {
        var phases: [GuardPhase] = [.disabled, .protected(reading)]
        for cause in [VerdictStaleness.Cause.coldStart, .networkChanged] {
            phases.append(.verifying(since: t0, cause: cause))
        }
        for reason in allReasons {
            phases.append(.paused(since: t0, reason: reason))
            for failures in 0...2 { phases.append(.interference(reading, reason: reason, failures: failures)) }
        }
        for evidence in allEvidence { phases.append(.danger(evidence)) }

        for phase in phases {
            let explanation = StatusPresentation.explanation(for: phase, remainingPause: 43)
            for text in [explanation.title, explanation.action, explanation.evidence, explanation.next] {
                XCTAssertFalse(text.isEmpty, "пустая клетка у \(phase)")
                XCTAssertFalse(text.contains("Optional") || text.contains("nil"), "сырой опционал у \(phase): \(text)")
            }
            XCTAssertEqual(explanation.title, phase.title)
        }
    }

    func test_verifying_explains_pause_reason_and_countdown() {
        let e = StatusPresentation.explanation(for: .verifying(since: t0, cause: .coldStart), remainingPause: 43)
        XCTAssertEqual(e.title, "Проверка")
        XCTAssertEqual(e.action, "Цели на паузе")
        XCTAssertEqual(e.evidence, "Подключение ещё не проверено: вердикта ещё не было")
        XCTAssertEqual(e.next, "Ждём подтверждения безопасного выхода, 43 с до завершения")
    }

    func test_protected_names_the_exit() {
        let e = StatusPresentation.explanation(for: .protected(reading), remainingPause: nil)
        XCTAssertEqual(e.action, "Ничего не сделано")
        XCTAssertEqual(e.evidence, "Выход 203.0.113.28, страна KZ подтверждена freeipapi")
        XCTAssertEqual(e.next, "Проверка повторяется каждые 5 с")
    }

    /// Счёт «ещё N проб — и пауза» обязан совпадать с тем, что реально сделает
    /// `GuardMachine.tolerate`, а не с формулой, переписанной рядом. Поэтому здесь
    /// не подставляется `failures` в готовую строку — состояние добывается прогоном
    /// настоящей машины через `.unproven`, и ожидание после каждого шага сверяется
    /// с тем, что делает следующий вызов `apply` (а не с `tolerance - failures`).
    func test_interference_counts_down_the_tolerance() {
        var machine = GuardMachine(phase: .protected(reading), tolerance: 2)
        let reason = UnprovenReason.geoUnavailable("таймаут запроса")
        let input = GuardInput.verdict(.unproven(reason), geo: .unavailable("таймаут запроса"))

        // Первая непроверенность из «Защищено»: тормозит на failures == 1, терпимость 2 —
        // впереди ещё две неудачи, прежде чем реальный `apply` уйдёт в паузу.
        _ = machine.apply(input, at: t0)
        XCTAssertEqual(machine.phase, .interference(reading, reason: reason, failures: 1))
        let e1 = StatusPresentation.explanation(for: machine.phase, remainingPause: nil, tolerance: machine.tolerance)
        XCTAssertEqual(e1.title, "Помехи")
        XCTAssertEqual(e1.action, "Ничего не сделано")
        XCTAssertEqual(e1.evidence, "Не удалось определить внешний адрес: таймаут запроса")
        XCTAssertEqual(e1.next, "Цели работают по вердикту KZ; ещё 2 неудачные пробы — и пауза")

        // Вторая подряд: осталась ровно одна терпимая проба.
        _ = machine.apply(input, at: t0)
        XCTAssertEqual(machine.phase, .interference(reading, reason: reason, failures: 2))
        let e2 = StatusPresentation.explanation(for: machine.phase, remainingPause: nil, tolerance: machine.tolerance)
        XCTAssertEqual(e2.next, "Цели работают по вердикту KZ; ещё 1 неудачная проба — и пауза")

        // Третья — обещанная «ещё 1» — обязана реально поставить на паузу, иначе
        // строка на предыдущем шаге солгала.
        let effect = machine.apply(input, at: t0)
        XCTAssertEqual(effect, .pause)
        guard case .paused = machine.phase else {
            return XCTFail("после обещанной последней пробы фаза обязана стать .paused, а не \(machine.phase)")
        }
    }

    func test_interference_from_a_proven_address_has_no_countdown() {
        let e = StatusPresentation.explanation(
            for: .interference(reading, reason: .geoUnavailable("таймаут запроса"), failures: 0), remainingPause: nil
        )
        XCTAssertEqual(e.next, "Цели работают: адрес 203.0.113.28 доказанно тот же")
    }

    func test_paused_explains_the_ceiling() {
        let e = StatusPresentation.explanation(for: .paused(since: t0, reason: .confirmationUnavailable), remainingPause: 12)
        XCTAssertEqual(e.action, "Цели на паузе")
        XCTAssertEqual(e.evidence, "Подтверждающие сервисы недоступны")
        XCTAssertEqual(e.next, "Ждём ответа сервисов, 12 с до завершения; возобновятся при подтверждении безопасного выхода")
    }

    func test_danger_forbids_launch() {
        let e = StatusPresentation.explanation(for: .danger(.blockedCountry(code: "RU", source: "ipinfo")), remainingPause: nil)
        XCTAssertEqual(e.action, "Цели завершены")
        XCTAssertEqual(e.evidence, "Обнаружена страна RU по данным ipinfo")
        XCTAssertEqual(e.next, "Запуск запрещён до подтверждения безопасного выхода")
    }

    func test_disabled_tells_what_to_do() {
        let e = StatusPresentation.explanation(for: .disabled, remainingPause: nil)
        XCTAssertEqual(e.action, "Ничего не сделано")
        XCTAssertEqual(e.evidence, "Цели не выбраны — охрана ничего не завершает")
        XCTAssertEqual(e.next, "Добавьте приложение или команду в настройках")
    }

    /// Отсчёт обязан читаться натурально и на границах: 60 с, 43 с, 1 с и — на исходе — 0 с.
    func test_countdown_reads_naturally_at_the_edges() {
        let sixty = StatusPresentation.explanation(for: .paused(since: t0, reason: .confirmationUnavailable), remainingPause: 60)
        XCTAssertEqual(sixty.next, "Ждём ответа сервисов, 60 с до завершения; возобновятся при подтверждении безопасного выхода")

        let one = StatusPresentation.explanation(for: .paused(since: t0, reason: .confirmationUnavailable), remainingPause: 1)
        XCTAssertEqual(one.next, "Ждём ответа сервисов, 1 с до завершения; возобновятся при подтверждении безопасного выхода")

        let zero = StatusPresentation.explanation(for: .paused(since: t0, reason: .confirmationUnavailable), remainingPause: 0)
        XCTAssertEqual(zero.next, "Ждём ответа сервисов, 0 с до завершения; возобновятся при подтверждении безопасного выхода")
    }

    /// `remainingPause` может не подъехать вовремя (например, `pauseDeadline` ещё не выставлен) —
    /// строка не имеет права падать или показывать отрицательное число.
    func test_countdown_survives_a_missing_deadline() {
        let e = StatusPresentation.explanation(for: .verifying(since: t0, cause: .coldStart), remainingPause: nil)
        XCTAssertEqual(e.next, "Ждём подтверждения безопасного выхода, 0 с до завершения")
    }

    // MARK: - Подсказка про незапущенные цели

    func test_idle_targets_hint_only_when_protected() {
        XCTAssertEqual(StatusPresentation.idleTargets(for: .protected(reading)).hint, "— VPN можно выключать")
        XCTAssertNil(StatusPresentation.idleTargets(for: .paused(since: t0, reason: .confirmationUnavailable)).hint)
        XCTAssertNil(StatusPresentation.idleTargets(for: .danger(.vpnAppNotRunning)).hint)
    }

    /// Совет «VPN можно выключать» имеет смысл ровно в одном состоянии — когда
    /// охрана на страже и подтвердила безопасность.
    func test_idle_targets_hint_offers_to_disconnect_only_when_protected() {
        let notice = StatusPresentation.idleTargets(for: .protected(reading))

        XCTAssertEqual(notice.text, "Цели не запущены")
        XCTAssertEqual(notice.hint, "— VPN можно выключать")
    }

    /// После срабатывания охраны цели молчат не потому, что всё хорошо:
    /// VPN уже выключен, и советовать выключить его — ложь.
    func test_idle_targets_hint_is_silent_after_the_kill_switch() {
        let notice = StatusPresentation.idleTargets(for: .danger(.vpnAppNotRunning))

        XCTAssertEqual(notice.text, "Цели не запущены")
        XCTAssertNil(notice.hint, "выключенный VPN не повод советовать его выключить")
    }

    func test_idle_targets_hint_is_silent_while_paused() {
        XCTAssertNil(
            StatusPresentation.idleTargets(for: .paused(since: t0, reason: .confirmationUnavailable)).hint
        )
        XCTAssertNil(StatusPresentation.idleTargets(for: .verifying(since: t0, cause: .coldStart)).hint)
    }

    func test_idle_targets_hint_is_silent_when_guard_is_off() {
        XCTAssertNil(StatusPresentation.idleTargets(for: .disabled).hint)
    }

    // MARK: - Строки по чтению и по отчёту пробы

    func test_lines_are_ip_and_both_sources() {
        XCTAssertEqual(
            StatusPresentation.lines(for: .protected(reading), reading: reading),
            [
                StatusLine(key: "IP", value: "203.0.113.28"),
                StatusLine(key: "ipinfo", value: "KZ"),
                StatusLine(key: "freeipapi", value: "KZ"),
            ]
        )
    }

    func test_lines_hide_the_reading_while_verifying() {
        XCTAssertEqual(
            StatusPresentation.lines(for: .verifying(since: t0, cause: .coldStart), reading: reading),
            [StatusLine(key: "IP", value: "неизвестен"), StatusLine(key: "ipinfo", value: "—"),
             StatusLine(key: "подтверждение", value: "—")]
        )
    }

    /// Под паузой вердикт по-прежнему про этот путь — прошлое чтение показывать честно:
    /// именно оно объясняет, почему цели стоят, а не завершены.
    func test_paused_still_shows_the_last_known_reading() {
        let lines = StatusPresentation.lines(
            for: .paused(since: t0, reason: .geoUnavailable("таймаут запроса")), reading: reading
        )
        XCTAssertEqual(lines.map(\.value), ["203.0.113.28", "KZ", "KZ"])
    }

    // 1770000000 = 2026-02-02 02:40:00 UTC
    private let moment = Date(timeIntervalSince1970: 1_770_000_000)

    func test_silent_ipinfo_shows_who_failed_instead_of_blank_dashes() {
        let report = GeoProbeReport(
            ip: nil,
            ipinfo: .failed(.timedOut(nil)),
            confirmation: .notRequested,
            confirmSource: nil,
            hasNetworkPath: true,
            checkedAt: moment
        )

        XCTAssertEqual(
            StatusPresentation.lines(
                for: .paused(since: t0, reason: .geoUnavailable("таймаут запроса")),
                report: report,
                timeZone: TimeZone(identifier: "UTC")!
            ),
            [
                StatusLine(key: "ipinfo", value: "таймаут запроса"),
                StatusLine(key: "подтверждение", value: "не запрашивалось"),
                StatusLine(key: "сеть", value: "есть"),
                StatusLine(key: "Проверено", value: "02:40:00"),
            ]
        )
    }

    func test_successful_probe_names_the_address_and_the_service_that_answered() {
        let report = GeoProbeReport(
            ip: "203.0.113.28",
            ipinfo: .answered("KZ"),
            confirmation: .answered("KZ"),
            confirmSource: .freeipapi,
            hasNetworkPath: true,
            checkedAt: moment
        )

        XCTAssertEqual(
            StatusPresentation.lines(
                for: .protected(reading),
                report: report,
                timeZone: TimeZone(identifier: "UTC")!
            ),
            [
                StatusLine(key: "IP", value: "203.0.113.28"),
                StatusLine(key: "ipinfo", value: "KZ"),
                StatusLine(key: "freeipapi", value: "KZ"),
                StatusLine(key: "Проверено", value: "02:40:00"),
            ]
        )
    }

    func test_detail_joins_lines_for_notifications() {
        XCTAssertEqual(
            StatusPresentation.detail(for: .protected(reading), reading: reading),
            "IP: 203.0.113.28 · ipinfo: KZ · freeipapi: KZ"
        )
    }

    func test_detail_is_nil_when_nothing_is_known() {
        XCTAssertNil(StatusPresentation.detail(for: .danger(.vpnAppNotRunning), reading: nil))
    }
}
