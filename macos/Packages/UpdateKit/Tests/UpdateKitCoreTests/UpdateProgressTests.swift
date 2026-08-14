import XCTest
@testable import UpdateKitCore

final class UpdateProgressTests: XCTestCase {

    func test_idle_is_not_in_flight() {
        XCTAssertFalse(UpdateProgress.idle.isInFlight)
    }

    func test_downloading_and_installing_are_in_flight() {
        XCTAssertTrue(UpdateProgress(phase: .downloading, fraction: 0.5).isInFlight)
        XCTAssertTrue(UpdateProgress(phase: .installing).isInFlight)
        XCTAssertTrue(UpdateProgress(phase: .checking).isInFlight)
    }

    func test_failure_is_not_in_flight() {
        XCTAssertFalse(UpdateProgress(phase: .failed, failure: "нет сети").isInFlight)
    }

    func test_fraction_is_clamped() {
        XCTAssertEqual(UpdateProgress(phase: .downloading, fraction: 1.4).fraction, 1)
        XCTAssertEqual(UpdateProgress(phase: .downloading, fraction: -0.2).fraction, 0)
    }

    func test_round_trip_through_the_xpc_triple() {
        let source = UpdateProgress(phase: .downloading, fraction: 0.62)
        let triple = source.xpc

        XCTAssertEqual(
            UpdateProgress.fromXPC(phase: triple.phase, fraction: triple.fraction, failure: triple.failure),
            source
        )
    }

    /// Старый демон, не знающий о прогрессе, не должен выглядеть закончившим:
    /// незнакомый код фазы читается как «идёт установка», а не как «простой».
    func test_unknown_phase_reads_as_installing() {
        let progress = UpdateProgress.fromXPC(phase: 42, fraction: 0, failure: nil)

        XCTAssertEqual(progress.phase, .installing)
        XCTAssertTrue(progress.isInFlight)
    }

    func test_failure_survives_the_triple() {
        let progress = UpdateProgress.fromXPC(phase: 4, fraction: 0, failure: "Установщик завершился с кодом 1")

        XCTAssertEqual(progress.phase, .failed)
        XCTAssertEqual(progress.failure, "Установщик завершился с кодом 1")
    }
}
