import XCTest
@testable import UpdateKitXPC

/// Демон в тестах не поднимается: проверяется отображение его ответов
/// и то, что клиент не выдумывает результат.
final class UpdaterServiceTests: XCTestCase {

    private final class HelperStub: NSObject, UpdaterHelperProtocol {
        let installError: String?
        let state: (Int, Double, String?)
        private(set) var installCalls = 0
        private(set) var stateCalls = 0

        init(installError: String? = nil, state: (Int, Double, String?) = (0, 0, nil)) {
            self.installError = installError
            self.state = state
        }

        func performUpdate(reply: @escaping (String?) -> Void) {
            installCalls += 1
            reply(installError)
        }

        func installState(reply: @escaping (Int, Double, String?) -> Void) {
            stateCalls += 1
            reply(state.0, state.1, state.2)
        }

        func uninstallHelper(reply: @escaping (String?) -> Void) { reply(nil) }
    }

    func test_silent_reply_means_the_install_started() {
        let helper = HelperStub()
        var result: UpdaterService.InstallResult?

        UpdaterService.install(helper: helper) { result = $0 }

        XCTAssertEqual(result, .started)
        XCTAssertEqual(helper.installCalls, 1)
    }

    func test_daemon_error_becomes_a_failure() {
        var result: UpdaterService.InstallResult?

        UpdaterService.install(helper: HelperStub(installError: "нет пакета в релизе")) { result = $0 }

        XCTAssertEqual(result, .failed("нет пакета в релизе"))
    }

    func test_state_is_passed_through_untouched() {
        let helper = HelperStub(state: (2, 0.62, nil))
        var received: (Int, Double, String?)?

        UpdaterService.state(helper: helper) { received = ($0, $1, $2) }

        XCTAssertEqual(received?.0, 2)
        XCTAssertEqual(received?.1 ?? 0, 0.62, accuracy: 0.0001)
        XCTAssertNil(received?.2 ?? nil)
        XCTAssertEqual(helper.stateCalls, 1)
    }

    func test_failure_state_carries_the_message() {
        var received: (Int, Double, String?)?

        UpdaterService.state(helper: HelperStub(state: (4, 0, "Установщик завершился с кодом 1"))) {
            received = ($0, $1, $2)
        }

        XCTAssertEqual(received?.0, 4)
        XCTAssertEqual(received?.2, "Установщик завершился с кодом 1")
    }
}
