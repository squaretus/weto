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

    /// Заголовок статуса — это состояние охраны, а не причина: шесть слов из `GuardPhase`,
    /// одинаковых на обеих платформах. Своего заголовка у представления больше нет.
    /// Объяснение тремя строками — задача 16.
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

    /// «Проверка» не знает про выход ничего: вердикта про текущий путь нет,
    /// и прошлые адрес со страной читались бы как «я всё ещё под VPN».
    func test_verifying_hides_stale_reading() {
        let lines = StatusPresentation.lines(
            for: .verifying(since: t0, cause: .networkChanged), reading: reading
        )
        XCTAssertEqual(lines.map(\.value), ["неизвестен", "—", "—"])
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

    // MARK: - Подсказка про незапущенные цели

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
}
