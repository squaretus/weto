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

    func test_disabled_state_says_guard_is_off() {
        XCTAssertEqual(StatusPresentation.title(for: .disabled), "Охрана выключена")
    }

    func test_safe_state_says_on_watch() {
        XCTAssertEqual(StatusPresentation.title(for: .safe(reading)), "На страже")
    }

    func test_degraded_titles_name_the_failing_service() {
        XCTAssertEqual(
            StatusPresentation.title(for: .unsafe(.geoUnavailable("таймаут"))),
            "Ipinfo недоступен"
        )
        XCTAssertEqual(
            StatusPresentation.title(for: .unsafe(.confirmationUnavailable)),
            "Подтверждение недоступно"
        )
    }

    func test_every_blocking_reason_reports_targets_terminated() {
        XCTAssertEqual(StatusPresentation.title(for: .unsafe(.vpnDown)), "Цели завершены")
        XCTAssertEqual(
            StatusPresentation.title(for: .unsafe(.blockedCountry(code: "RU", source: "ipinfo"))),
            "Цели завершены"
        )
    }

    func test_pending_verification_names_the_check_in_progress() {
        XCTAssertEqual(
            StatusPresentation.title(for: .unsafe(.verificationPending)),
            "Проверка подключения"
        )
    }

    func test_pending_verification_is_blocking_rather_than_degraded() {
        XCTAssertEqual(GuardState.unsafe(.verificationPending).statusColor, .red)
    }

    func test_lines_are_ip_and_both_sources() {
        XCTAssertEqual(
            StatusPresentation.lines(for: .safe(reading), reading: reading),
            [
                StatusLine(key: "IP", value: "203.0.113.28"),
                StatusLine(key: "ipinfo", value: "KZ"),
                StatusLine(key: "freeipapi", value: "KZ"),
            ]
        )
    }

    func test_missing_confirmation_shows_a_dash() {
        let degraded = GeoReading(
            ip: "203.0.113.28", primaryCountry: "KZ",
            confirmedCountry: nil, confirmSource: nil
        )
        XCTAssertEqual(
            StatusPresentation.lines(for: .unsafe(.confirmationUnavailable), reading: degraded),
            [
                StatusLine(key: "IP", value: "203.0.113.28"),
                StatusLine(key: "ipinfo", value: "KZ"),
                StatusLine(key: "подтверждение", value: "—"),
            ]
        )
    }

    func test_unreachable_ipinfo_hides_stale_reading() {
        let lines = StatusPresentation.lines(
            for: .unsafe(.geoUnavailable("таймаут")), reading: reading
        )
        XCTAssertEqual(lines.map(\.value), ["неизвестен", "—", "—"])
    }

    // 1770000000 = 2026-02-02 02:40:00 UTC
    private let moment = Date(timeIntervalSince1970: 1_770_000_000)

    func test_silent_ipinfo_shows_who_failed_instead_of_blank_dashes() {
        let report = GeoProbeReport(
            ip: nil,
            ipinfo: .failed(.timedOut),
            confirmation: .notRequested,
            confirmSource: nil,
            hasNetworkPath: true,
            checkedAt: moment
        )

        XCTAssertEqual(
            StatusPresentation.lines(
                for: .unsafe(.geoUnavailable("таймаут запроса")),
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
                for: .safe(reading),
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
            StatusPresentation.detail(for: .safe(reading), reading: reading),
            "IP: 203.0.113.28 · ipinfo: KZ · freeipapi: KZ"
        )
    }

    func test_detail_is_nil_when_nothing_is_known() {
        XCTAssertNil(StatusPresentation.detail(for: .unsafe(.vpnDown), reading: nil))
    }

    func test_status_color_marks_geo_outage_as_degraded() {
        XCTAssertEqual(GuardState.safe(reading).statusColor, .green)
        XCTAssertEqual(GuardState.unsafe(.geoUnavailable("таймаут")).statusColor, .yellow)
        XCTAssertEqual(GuardState.unsafe(.confirmationUnavailable).statusColor, .yellow)
        XCTAssertEqual(GuardState.unsafe(.vpnDown).statusColor, .red)
    }
}
