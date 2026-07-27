import XCTest
@testable import WetoShared
import WetoCore

final class StatusPresentationTests: XCTestCase {

    private let reading = GeoReading(
        ip: "203.0.113.28",
        asn: "AS49791",
        primaryCountry: "KZ",
        confirmedCountry: "KZ",
        confirmSource: .ipwhois
    )

    func test_disabled_state_says_guard_is_off() {
        XCTAssertEqual(StatusPresentation.headline(for: .disabled), "Охрана выключена")
    }

    func test_safe_state_says_everything_is_fine() {
        XCTAssertEqual(StatusPresentation.headline(for: .safe(reading)), "Всё в порядке")
    }

    func test_unsafe_headline_uses_reason_text() {
        XCTAssertEqual(StatusPresentation.headline(for: .unsafe(.vpnDown)), "VPN не поднят")
        XCTAssertEqual(
            StatusPresentation.headline(for: .unsafe(.confirmationUnavailable)),
            "Подтверждающие сервисы недоступны"
        )
    }

    func test_detail_shows_ip_asn_and_both_countries() {
        XCTAssertEqual(
            StatusPresentation.detail(for: .safe(reading), reading: reading),
            "203.0.113.28 · ipinfo: KZ · ipwhois: KZ"
        )
    }

    func test_detail_marks_missing_confirmation() {
        let degraded = GeoReading(
            ip: "203.0.113.28", asn: "AS49791", primaryCountry: "KZ",
            confirmedCountry: nil, confirmSource: nil
        )
        XCTAssertEqual(
            StatusPresentation.detail(for: .unsafe(.confirmationUnavailable), reading: degraded),
            "203.0.113.28 · ipinfo: KZ · подтверждение: нет"
        )
    }

    func test_detail_is_nil_when_nothing_is_known() {
        XCTAssertNil(StatusPresentation.detail(for: .unsafe(.vpnDown), reading: nil))
    }

    func test_banner_tone_matches_status_color() {
        XCTAssertEqual(StatusPresentation.bannerTone(for: .disabled), .info)
        XCTAssertEqual(StatusPresentation.bannerTone(for: .safe(reading)), .success)
        XCTAssertEqual(StatusPresentation.bannerTone(for: .unsafe(.confirmationUnavailable)), .warn)
        XCTAssertEqual(StatusPresentation.bannerTone(for: .unsafe(.vpnDown)), .error)
    }
}
