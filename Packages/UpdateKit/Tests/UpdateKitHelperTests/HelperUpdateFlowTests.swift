import XCTest
import UpdateKitCore
@testable import UpdateKitHelper

final class HelperUpdateFlowTests: XCTestCase {

    private let configuration = UpdateFeedConfiguration.testing

    private func info(latest: String, isNewer: Bool, downloadURL: String) -> UpdateInfo {
        UpdateInfo(
            currentVersion: "0.4.0",
            latestVersion: latest,
            releaseURL: "https://github.com/example/sample/releases/tag/v\(latest)",
            downloadURL: downloadURL,
            releaseNotes: nil,
            isNewer: isNewer
        )
    }

    private func makeFlow(
        state: HelperInstallState,
        release: Result<UpdateInfo, Error>,
        download: Result<String, Error> = .success("/var/db/sample/updates/update.pkg"),
        install: Error? = nil,
        installed: @escaping @Sendable () -> Void = {}
    ) -> HelperUpdateFlow {
        HelperUpdateFlow(
            configuration: configuration,
            state: state,
            checkRelease: { _, completion in completion(release) },
            download: { _, onProgress, completion in
                onProgress(0.5)
                completion(download)
            },
            install: { _ in
                installed()
                if let install { throw install }
            }
        )
    }

    func test_missing_installed_version_refuses_to_install() {
        let state = HelperInstallState()
        let installed = Flag()
        let flow = makeFlow(
            state: state,
            release: .success(info(latest: "0.4.2", isNewer: true, downloadURL: "https://example/Sample.pkg")),
            installed: { installed.raise() }
        )

        var reply: String?
        flow.start(currentVersion: nil) { reply = $0 }

        XCTAssertEqual(reply, "Не удалось прочитать версию установленного приложения")
        XCTAssertFalse(installed.isRaised, "подставлять 0.0.0 нельзя: любой релиз оказался бы новее")
        XCTAssertEqual(state.current, .idle)
    }

    func test_release_without_a_package_is_refused_before_download() {
        let state = HelperInstallState()
        let flow = makeFlow(
            state: state,
            release: .success(info(latest: "0.4.2", isNewer: true, downloadURL: ""))
        )

        var reply: String?
        flow.start(currentVersion: "0.4.0") { reply = $0 }

        XCTAssertEqual(reply, "В релизе нет файла .pkg")
        XCTAssertEqual(state.current, .idle)
    }

    func test_no_newer_release_is_refused() {
        let flow = makeFlow(
            state: HelperInstallState(),
            release: .success(info(latest: "0.4.0", isNewer: false, downloadURL: "https://example/Sample.pkg"))
        )

        var reply: String?
        flow.start(currentVersion: "0.4.0") { reply = $0 }

        XCTAssertEqual(reply, "Обновления нет: установлена 0.4.0")
    }

    func test_successful_flow_answers_before_downloading_and_reports_progress() {
        let state = HelperInstallState()
        let installedPath = Box()
        let flow = HelperUpdateFlow(
            configuration: configuration,
            state: state,
            checkRelease: { _, completion in
                completion(.success(self.info(
                    latest: "0.4.2",
                    isNewer: true,
                    downloadURL: "https://example/Sample.pkg"
                )))
            },
            download: { _, onProgress, completion in
                onProgress(0.62)
                XCTAssertEqual(state.current.phase, .downloading)
                XCTAssertEqual(state.current.fraction, 0.62, accuracy: 0.0001)
                completion(.success("/var/db/sample/updates/update.pkg"))
            },
            install: { path in installedPath.value = path }
        )

        var reply: String?
        var replied = false
        flow.start(currentVersion: "0.4.0") { reply = $0; replied = true }

        XCTAssertTrue(replied)
        XCTAssertNil(reply, "ответ «установка начата» уходит до скачивания")
        XCTAssertEqual(installedPath.value, "/var/db/sample/updates/update.pkg")
        XCTAssertEqual(state.current, .idle)
    }

    func test_download_failure_is_remembered_for_the_client() {
        struct Boom: LocalizedError { var errorDescription: String? { "нет сети" } }
        let state = HelperInstallState()
        let flow = makeFlow(
            state: state,
            release: .success(info(latest: "0.4.2", isNewer: true, downloadURL: "https://example/Sample.pkg")),
            download: .failure(Boom())
        )

        flow.start(currentVersion: "0.4.0") { _ in }

        XCTAssertEqual(state.current.phase, .failed)
        XCTAssertEqual(state.current.failure, "Не удалось скачать пакет: нет сети")
    }

    func test_install_failure_is_remembered_for_the_client() {
        struct Boom: LocalizedError { var errorDescription: String? { "код 1" } }
        let state = HelperInstallState()
        let flow = makeFlow(
            state: state,
            release: .success(info(latest: "0.4.2", isNewer: true, downloadURL: "https://example/Sample.pkg")),
            install: Boom()
        )

        flow.start(currentVersion: "0.4.0") { _ in }

        XCTAssertEqual(state.current.phase, .failed)
        XCTAssertEqual(state.current.failure, "Установка не удалась: код 1")
    }
}

/// Замыкания границ помечены `@Sendable`, поэтому писать в локальную переменную
/// из них нельзя — наблюдения складываем в маленькие потокобезопасные коробки.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func raise() { lock.lock(); raised = true; lock.unlock() }

    var isRaised: Bool {
        lock.lock(); defer { lock.unlock() }
        return raised
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
