import XCTest
@testable import WetoXPC

/// Демон в тестах не поднимается: проверяется отображение его ответов
/// в результаты для UI и то, что клиент не выдумывает результат.
final class UpdateServiceTests: XCTestCase {

    /// Заглушка демона: отвечает тем, что положили, и считает вызовы.
    private final class HelperStub: NSObject, WetoHelperProtocol {
        let installError: String?
        let failure: String?
        private(set) var installCalls = 0
        private(set) var failureCalls = 0

        init(installError: String? = nil, failure: String? = nil) {
            self.installError = installError
            self.failure = failure
        }

        func performUpdate(reply: @escaping (String?) -> Void) {
            installCalls += 1
            reply(installError)
        }

        func lastInstallFailure(reply: @escaping (String?) -> Void) {
            failureCalls += 1
            reply(failure)
        }

        func uninstallHelper(reply: @escaping (String?) -> Void) { reply(nil) }
    }

    func test_silent_reply_means_the_install_started() {
        let helper = HelperStub()
        var result: UpdateService.InstallResult?

        UpdateService.install(helper: helper) { result = $0 }

        XCTAssertEqual(result, .started)
        XCTAssertEqual(helper.installCalls, 1)
    }

    func test_daemon_error_becomes_a_failure() {
        var result: UpdateService.InstallResult?

        UpdateService.install(helper: HelperStub(installError: "нет пакета в релизе")) { result = $0 }

        XCTAssertEqual(result, .failed("нет пакета в релизе"))
    }

    func test_late_failure_is_passed_through() {
        let helper = HelperStub(failure: "Установка не удалась: код 1")
        var failure: String??

        UpdateService.lastFailure(helper: helper) { failure = $0 }

        XCTAssertEqual(failure, "Установка не удалась: код 1")
        XCTAssertEqual(helper.failureCalls, 1)
    }

    func test_no_late_failure_is_not_an_error() {
        var failure: String??

        UpdateService.lastFailure(helper: HelperStub()) { failure = $0 }

        XCTAssertEqual(failure, .some(nil))
    }

    func test_mach_service_name_is_pinned() {
        XCTAssertEqual(WetoXPCConstants.machServiceName, "com.weto.helper")
    }
}
