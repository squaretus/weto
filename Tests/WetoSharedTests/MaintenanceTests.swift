import XCTest
@testable import WetoShared
import WetoCore
import WetoSystem

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

@MainActor
final class MaintenanceTests: XCTestCase {

    private var caches: URL!
    private var recorder: StepRecorder!

    override func setUpWithError() throws {
        recorder = StepRecorder()
        caches = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("weto-caches-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: caches)
    }

    private func makeMaintenance(
        agentDisable: Result<Void, LaunchAgentError> = .success(()),
        secretsResult: Result<Void, SecretStoreError> = .success(()),
        bundlePath: String? = "/Applications/Weto.app",
        removeBundle: (@Sendable (String) -> Result<Void, Error>)? = nil
    ) -> Maintenance {
        let localRecorder = recorder!
        return Maintenance(
            agent: FakeAgent(recorder: localRecorder, disableResult: agentDisable),
            secrets: RecordingSecrets(recorder: localRecorder, result: secretsResult),
            defaultsSuite: "com.weto.tests.\(UUID().uuidString)",
            cachesDirectory: caches,
            bundlePath: bundlePath,
            removeBundle: removeBundle ?? { path in
                localRecorder.record("bundle.remove(\(path))")
                return .success(())
            }
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
            .removeToken,
            .removeCaches,
            .scheduleBundleRemoval,
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: caches.path))
    }

    func test_agent_is_unloaded_before_the_bundle_removal_is_scheduled() {

        _ = makeMaintenance().uninstall()

        let steps = recorder.recorded
        let agentIndex = steps.firstIndex(of: "agent.disable")
        let bundleIndex = steps.firstIndex { $0.hasPrefix("bundle.remove") }

        XCTAssertNotNil(agentIndex)
        XCTAssertNotNil(bundleIndex)
        XCTAssertLessThan(agentIndex ?? .max, bundleIndex ?? .min)
    }

    func test_launchd_failure_is_reported_and_does_not_stop_other_steps() {
        let result = makeMaintenance(agentDisable: .failure(.bootout(5))).uninstall()

        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.failures.map(\.step), [.unloadAgent])
        XCTAssertTrue(result.failureText?.contains("launchd") == true)
        XCTAssertTrue(result.completed.contains(.clearSettings), "остальные шаги всё равно выполняются")
        XCTAssertTrue(result.completed.contains(.scheduleBundleRemoval))
    }

    func test_keychain_failure_is_reported() {
        let result = makeMaintenance(secretsResult: .failure(.keychain(-25293))).uninstall()

        XCTAssertEqual(result.failures.map(\.step), [.removeToken])
        XCTAssertTrue(result.failureText?.contains("-25293") == true)
    }

    func test_bundle_removal_failure_is_reported() {
        struct Denied: LocalizedError {
            var errorDescription: String? { "нет прав" }
        }

        let result = makeMaintenance(removeBundle: { _ in .failure(Denied()) }).uninstall()

        XCTAssertEqual(result.failures.map(\.step), [.scheduleBundleRemoval])
        XCTAssertTrue(result.failureText?.contains("нет прав") == true)
    }

    func test_uninstall_from_a_non_bundle_run_skips_bundle_removal() {

        let result = makeMaintenance(bundlePath: nil).uninstall()

        XCTAssertTrue(result.isSuccess)
        XCTAssertFalse(result.completed.contains(.scheduleBundleRemoval))
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
