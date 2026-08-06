import XCTest
import UpdateKitCore
@testable import UpdateKitHelper

final class HelperInstallStateTests: XCTestCase {

    func test_fresh_state_is_idle() {
        XCTAssertEqual(HelperInstallState().current, .idle)
    }

    func test_begin_reports_checking() {
        let state = HelperInstallState()
        XCTAssertTrue(state.begin())
        XCTAssertEqual(state.current.phase, .checking)
    }

    /// Вторая установка поверх идущей не начинается: демон под root не должен
    /// качать два пакета сразу.
    func test_second_begin_is_refused_while_installing() {
        let state = HelperInstallState()
        XCTAssertTrue(state.begin())
        XCTAssertFalse(state.begin())
    }

    func test_download_fraction_is_visible() {
        let state = HelperInstallState()
        _ = state.begin()
        state.report(fraction: 0.42)

        XCTAssertEqual(state.current.phase, .downloading)
        XCTAssertEqual(state.current.fraction, 0.42, accuracy: 0.0001)
    }

    func test_installing_phase_drops_the_fraction() {
        let state = HelperInstallState()
        _ = state.begin()
        state.report(fraction: 0.9)
        state.beginInstalling()

        XCTAssertEqual(state.current.phase, .installing)
        XCTAssertEqual(state.current.fraction, 0)
    }

    func test_failure_is_remembered_and_unlocks_the_next_attempt() {
        let state = HelperInstallState()
        _ = state.begin()
        state.finish(failure: "Не удалось скачать пакет: нет сети")

        XCTAssertEqual(state.current.phase, .failed)
        XCTAssertEqual(state.current.failure, "Не удалось скачать пакет: нет сети")
        XCTAssertTrue(state.begin(), "после провала повторная попытка разрешена")
    }

    /// Успех демон не отчитывает: установщик выгружает и приложение, и его самого.
    func test_success_returns_to_idle() {
        let state = HelperInstallState()
        _ = state.begin()
        state.finish(failure: nil)

        XCTAssertEqual(state.current, .idle)
    }
}
