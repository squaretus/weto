import XCTest
@testable import WetoCore

final class GeoProbeReportTests: XCTestCase {

    private let moment = Date(timeIntervalSince1970: 1_770_000_000)

    func test_answered_sources_make_up_a_resolved_reading() {
        let report = GeoProbeReport(
            ip: "203.0.113.28",
            ipinfo: .answered("KZ"),
            confirmation: .answered("KZ"),
            confirmSource: .freeipapi,
            hasNetworkPath: true,
            checkedAt: moment
        )

        XCTAssertEqual(
            report.outcome,
            .resolved(GeoReading(
                ip: "203.0.113.28",
                primaryCountry: "KZ",
                confirmedCountry: "KZ",
                confirmSource: .freeipapi
            ))
        )
    }

    func test_failed_ipinfo_carries_its_reason_into_the_verdict() {
        let report = GeoProbeReport(
            ip: nil,
            ipinfo: .failed(.timedOut),
            confirmation: .notRequested,
            confirmSource: nil,
            hasNetworkPath: true,
            checkedAt: moment
        )

        XCTAssertEqual(report.outcome, .unavailable("таймаут запроса"))
    }
}
