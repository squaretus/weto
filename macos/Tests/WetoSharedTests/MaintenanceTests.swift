import XCTest
@testable import WetoShared
import WetoCore
import WetoSystem
import UpdateKit

private final class StepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [String] = []

    func record(_ step: String) {
        lock.lock(); steps.append(step); lock.unlock()
    }

    var recorded: [String] {
        lock.lock(); defer { lock.unlock() }
        return steps
    }
}

private struct FakeAgent: LaunchAgentManaging {
    let recorder: StepRecorder
    let plistPath = "/tmp/weto-fake/com.weto.app.plist"
    let isInstalled = true
    let pointsAtCurrentBundle = true
    let disableResult: Result<Void, LaunchAgentError>

    init(recorder: StepRecorder, disableResult: Result<Void, LaunchAgentError> = .success(())) {
        self.recorder = recorder
        self.disableResult = disableResult
    }

    func enable() -> Result<Void, LaunchAgentError> { .success(()) }

    func disable() -> Result<Void, LaunchAgentError> {
        recorder.record("agent.disable")
        return disableResult
    }

    func bootout() -> Result<Void, LaunchAgentError> {
        recorder.record("agent.bootout")
        return disableResult
    }
}

private struct RecordingSecrets: SecretStoring {
    let recorder: StepRecorder
    let result: Result<Void, SecretStoreError>

    func read(account: String) -> String? { nil }

    func write(_ value: String?, account: String) -> Result<Void, SecretStoreError> {
        recorder.record("secrets.write")
        return result
    }
}

/// Демон удаляет и себя, и бандл приложения: у приложения нет прав на /Applications,
/// бандл принадлежит root.
private struct FakeHelperUninstaller: HelperUninstalling {
    let recorder: StepRecorder
    let failure: String?
    let removes: String?

    func uninstallHelper(completion: @escaping @Sendable (String?) -> Void) {
        recorder.record("helper.uninstall")
        if let removes { try? FileManager.default.removeItem(atPath: removes) }
        completion(failure)
    }
}

@MainActor
final class MaintenanceTests: XCTestCase {

    private var caches: URL!
    private var journals: URL!
    private var bundle: URL!
    private var recorder: StepRecorder!

    override func setUpWithError() throws {
        recorder = StepRecorder()
        caches = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("weto-caches-\(UUID().uuidString)", isDirectory: true)
        journals = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("weto-journals-\(UUID().uuidString)", isDirectory: true)
        bundle = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Weto-\(UUID().uuidString).app", isDirectory: true)
        for directory in [caches!, journals!, bundle!] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data().write(to: journals.appendingPathComponent("journal.json"))
        try Data().write(to: journals.appendingPathComponent("checks.json"))
    }

    override func tearDownWithError() throws {
        for directory in [caches, journals, bundle].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeMaintenance(
        agentDisable: Result<Void, LaunchAgentError> = .success(()),
        secretsResult: Result<Void, SecretStoreError> = .success(()),
        helperFailure: String? = nil,
        withBundle: Bool = true,
        removesBundle: Bool = true
    ) -> Maintenance {
        let localRecorder = recorder!
        let bundle: String? = withBundle ? self.bundle.path : nil
        return Maintenance(
            agent: FakeAgent(recorder: localRecorder, disableResult: agentDisable),
            helper: FakeHelperUninstaller(
                recorder: localRecorder,
                failure: helperFailure,
                removes: removesBundle ? bundle : nil
            ),
            secrets: RecordingSecrets(recorder: localRecorder, result: secretsResult),
            defaultsSuite: "com.weto.tests.\(UUID().uuidString)",
            cachesDirectory: caches,
            journalsDirectory: journals,
            bundlePath: bundle
        )
    }

    func test_successful_uninstall_lists_every_removed_resource() {
        let result = makeMaintenance().uninstall()

        XCTAssertTrue(result.isSuccess)
        XCTAssertNil(result.failureText)
        XCTAssertEqual(result.completed, [
            .unloadAgent,
            .removeAgentFile,
            .clearSettings,
            .removeJournals,
            .removeToken,
            .removeCaches,
            .removeHelper,
            .removeBundle,
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: caches.path))
    }

    /// Агент выгружается раньше, чем демон уносит бандл: иначе launchd остаётся
    /// с заданием, которое ссылается на исчезнувший файл.
    func test_the_agent_is_unloaded_before_the_daemon_takes_the_bundle_away() {
        _ = makeMaintenance().uninstall()

        let steps = recorder.recorded
        let agentIndex = steps.firstIndex(of: "agent.disable")
        let helperIndex = steps.firstIndex(of: "helper.uninstall")

        XCTAssertNotNil(agentIndex)
        XCTAssertNotNil(helperIndex)
        XCTAssertLessThan(agentIndex ?? .max, helperIndex ?? .min)
    }

    func test_helper_failure_is_reported() {

        let result = makeMaintenance(helperFailure: "нет прав на /Library").uninstall()

        XCTAssertEqual(result.failures.map(\.step), [.removeHelper])
        XCTAssertTrue(result.failureText?.contains("нет прав") == true)
    }

    /// Бандл проверяется после демона, а не до: удаляет его именно демон,
    /// и до его ответа приложение ещё на месте.
    func test_the_bundle_is_checked_after_the_daemon_has_answered() {
        let result = makeMaintenance().uninstall()

        let helperIndex = result.completed.firstIndex(of: .removeHelper)
        let bundleIndex = result.completed.firstIndex(of: .removeBundle)

        XCTAssertNotNil(helperIndex)
        XCTAssertNotNil(bundleIndex)
        XCTAssertLessThan(helperIndex ?? .max, bundleIndex ?? .min)
    }

    func test_launchd_failure_is_reported_and_does_not_stop_other_steps() {
        let result = makeMaintenance(agentDisable: .failure(.bootout(5))).uninstall()

        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.failures.map(\.step), [.unloadAgent])
        XCTAssertTrue(result.failureText?.contains("launchd") == true)
        XCTAssertTrue(result.completed.contains(.clearSettings), "остальные шаги всё равно выполняются")
        XCTAssertTrue(result.completed.contains(.removeBundle))
    }

    func test_keychain_failure_is_reported() {
        let result = makeMaintenance(secretsResult: .failure(.keychain(-25293))).uninstall()

        XCTAssertEqual(result.failures.map(\.step), [.removeToken])
        XCTAssertTrue(result.failureText?.contains("-25293") == true)
    }

    func test_uninstall_from_a_non_bundle_run_skips_bundle_removal() {

        let result = makeMaintenance(withBundle: false).uninstall()

        XCTAssertTrue(result.isSuccess)
        XCTAssertFalse(result.completed.contains(.removeBundle))
    }

    /// Журналы завершений и проверок лежат отдельным каталогом, и удаление
    /// про них не знало вовсе: после «удалить приложение» на диске оставалось
    /// шестьдесят килобайт истории.
    func test_uninstall_removes_the_journals() {
        let result = makeMaintenance().uninstall()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: journals.path),
            "каталог журналов обязан уйти вместе с приложением"
        )
        XCTAssertTrue(result.completed.contains(.removeJournals))
    }

    /// Бандл принадлежит root — его ставит PKG, — и удалить его может только
    /// демон. Приложение обязано проверить результат, а не поверить в него:
    /// раньше оно рапортовало об успехе, запустив скрипт, у которого не было прав.
    func test_a_bundle_left_on_disk_is_reported_as_a_failure() {
        let result = makeMaintenance(removesBundle: false).uninstall()

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(
            result.failureText?.contains(bundle.path) ?? false,
            "в отчёте обязан быть путь, который остался: «\(result.failureText ?? "")»"
        )
    }

    func test_a_removed_bundle_is_reported_as_done() {
        let result = makeMaintenance().uninstall()

        XCTAssertTrue(result.isSuccess, result.failureText ?? "")
        XCTAssertTrue(result.completed.contains(.removeBundle))
    }

    func test_close_app_only_unloads_the_agent() {
        let maintenance = makeMaintenance()

        XCTAssertTrue(maintenance.closeApp().isSuccess)
        XCTAssertEqual(recorder.recorded, ["agent.bootout"])
    }

    func test_close_app_reports_launchd_failure() {
        let maintenance = makeMaintenance(agentDisable: .failure(.bootout(5)))
        XCTAssertEqual(maintenance.closeApp().failureValue, .bootout(5))
    }
}
