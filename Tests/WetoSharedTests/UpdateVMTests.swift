import XCTest
@testable import WetoShared
import WetoCore
import WetoSystem
import UpdateKitCore
import UpdateKitXPC

private actor CountingFetcher: HTTPFetching {
    private let payload: Data
    private var calls = 0

    init(payload: Data) { self.payload = payload }

    func data(from url: URL, headers: [String: String]) async throws -> Data {
        calls += 1
        return payload
    }

    func count() -> Int { calls }
}

private final class SpyURLOpener: URLOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [URL] = []

    func open(_ url: URL) {
        lock.lock(); opened.append(url); lock.unlock()
    }

    var urls: [URL] {
        lock.lock(); defer { lock.unlock() }
        return opened
    }
}

private final class StubInstaller: UpdateInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private let outcome: UpdaterService.InstallResult?
    private let lateFailure: String?
    private var requests = 0

    init(_ outcome: UpdaterService.InstallResult?, lateFailure: String? = nil) {
        self.outcome = outcome
        self.lateFailure = lateFailure
    }

    func requestInstall(completion: @escaping @Sendable (UpdaterService.InstallResult?) -> Void) {
        lock.lock(); requests += 1; lock.unlock()
        completion(outcome)
    }

    func requestProgress(completion: @escaping @Sendable (UpdateProgress?) -> Void) {
        completion(lateFailure.map { UpdateProgress(phase: .failed, failure: $0) } ?? .idle)
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
}

@MainActor
final class UpdateVMTests: XCTestCase {

    private func release(tag: String, url: String = "https://github.com/squaretus/weto/releases/tag/v9.9.9") -> Data {
        Data("""
        {"tag_name":"\(tag)","html_url":"\(url)","assets":[
          {"name":"Weto-9.9.9.pkg",
           "browser_download_url":"https://github.com/squaretus/weto/releases/download/v9.9.9/Weto-9.9.9.pkg"}
        ]}
        """.utf8)
    }

    /// Тег без собранного пакета: `ReleaseParser` оставляет ссылку пустой.
    private func releaseWithoutPackage(tag: String) -> Data {
        Data("""
        {"tag_name":"\(tag)","html_url":"https://github.com/squaretus/weto/releases/tag/v\(tag)","assets":[]}
        """.utf8)
    }

    func test_release_page_can_be_opened_without_rechecking() async {
        let fetcher = CountingFetcher(payload: release(tag: "v9.9.9"))
        let opener = SpyURLOpener()
        let vm = UpdateVM(fetcher: fetcher, opener: opener, currentVersion: "1.0.0")

        await vm.checkForUpdateAndWait()
        guard case .available(let info) = vm.state else {
            return XCTFail("ожидалось состояние .available, получено \(vm.state)")
        }

        vm.openReleasePage()

        XCTAssertEqual(opener.urls.map(\.absoluteString), [info.releaseURL])
        let calls = await fetcher.count()
        XCTAssertEqual(calls, 1, "открытие релиза не должно повторно опрашивать GitHub")
    }

    func test_available_update_is_published_for_the_menu_bar() async {

        let vm = UpdateVM(
            fetcher: CountingFetcher(payload: release(tag: "v9.9.9")),
            opener: SpyURLOpener(),
            currentVersion: "1.0.0"
        )
        XCTAssertNil(vm.availableUpdate, "до проверки обновления показывать нечего")

        await vm.checkForUpdateAndWait()

        XCTAssertEqual(vm.availableUpdate?.latestVersion, "9.9.9")
        XCTAssertEqual(vm.availableUpdate?.currentVersion, "1.0.0")
    }

    func test_up_to_date_publishes_no_available_update() async {
        let vm = UpdateVM(
            fetcher: CountingFetcher(payload: release(tag: "v0.0.1")),
            opener: SpyURLOpener(),
            currentVersion: "1.0.0"
        )

        await vm.checkForUpdateAndWait()

        XCTAssertNil(vm.availableUpdate)
    }

    func test_up_to_date_state_rechecks_instead_of_opening() async {
        let fetcher = CountingFetcher(payload: release(tag: "v0.0.1"))
        let opener = SpyURLOpener()
        let vm = UpdateVM(fetcher: fetcher, opener: opener, currentVersion: "1.0.0")

        await vm.checkForUpdateAndWait()
        vm.primaryAction()
        await vm.checkForUpdateAndWait()

        XCTAssertTrue(opener.urls.isEmpty)
        let calls = await fetcher.count()
        XCTAssertGreaterThan(calls, 1)
    }

    func test_second_start_does_not_create_a_second_loop() async {
        let fetcher = CountingFetcher(payload: release(tag: "v0.0.1"))
        let vm = UpdateVM(fetcher: fetcher, opener: SpyURLOpener(), currentVersion: "1.0.0")

        vm.startPeriodicCheck()
        vm.startPeriodicCheck()
        vm.startPeriodicCheck()
        await vm.checkForUpdateAndWait()

        let calls = await fetcher.count()
        XCTAssertEqual(calls, 1, "повторный старт не должен множить проверки")
        vm.stop()
    }

    func test_stop_cancels_periodic_and_allows_restart() async {
        let vm = UpdateVM(
            fetcher: CountingFetcher(payload: release(tag: "v0.0.1")),
            opener: SpyURLOpener(),
            currentVersion: "1.0.0"
        )

        vm.startPeriodicCheck()
        vm.stop()
        vm.startPeriodicCheck()
        vm.stop()
    }

    /// Ответ установщика применяется в задаче на главном акторе — даём ей добежать.
    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    private func makeVM(
        tag: String = "v9.9.9",
        installer: UpdateInstalling,
        opener: SpyURLOpener
    ) -> UpdateVM {
        UpdateVM(
            fetcher: CountingFetcher(payload: release(tag: tag)),
            opener: opener,
            installer: installer,
            currentVersion: "1.0.0"
        )
    }

    func test_available_update_is_installed_by_the_daemon() async {

        let installer = StubInstaller(.started)
        let opener = SpyURLOpener()
        let vm = makeVM(installer: installer, opener: opener)
        await vm.checkForUpdateAndWait()

        vm.primaryAction()

        XCTAssertEqual(installer.requestCount, 1)
        XCTAssertTrue(vm.isInstallingUpdate, "начатая установка обязана быть видна в UI")
        XCTAssertTrue(opener.urls.isEmpty, "при работающем демоне браузер не нужен")
    }

    func test_daemon_failure_is_shown_and_spinner_stops() async {
        let vm = makeVM(installer: StubInstaller(.failed("нет пакета в релизе")), opener: SpyURLOpener())
        await vm.checkForUpdateAndWait()

        vm.primaryAction()
        await settle()

        XCTAssertFalse(vm.isInstallingUpdate)
        XCTAssertEqual(vm.installFailure, "нет пакета в релизе")
    }

    func test_missing_daemon_falls_back_to_release_page() async {

        let opener = SpyURLOpener()
        let vm = makeVM(installer: StubInstaller(nil), opener: opener)
        await vm.checkForUpdateAndWait()

        vm.primaryAction()
        await settle()

        XCTAssertFalse(vm.isInstallingUpdate)
        XCTAssertEqual(opener.urls.count, 1, "без демона остаётся страница релиза")
        XCTAssertNotNil(vm.installFailure)
    }

    func test_install_is_not_started_twice() async {
        let installer = StubInstaller(.started)
        let vm = makeVM(installer: installer, opener: SpyURLOpener())
        await vm.checkForUpdateAndWait()

        vm.primaryAction()
        vm.primaryAction()
        vm.primaryAction()

        XCTAssertEqual(installer.requestCount, 1, "повторные нажатия не должны множить установку")
    }

    func test_no_update_means_no_install_request() async {
        let installer = StubInstaller(.started)
        let vm = makeVM(tag: "v0.0.1", installer: installer, opener: SpyURLOpener())
        await vm.checkForUpdateAndWait()

        vm.primaryAction()

        XCTAssertEqual(installer.requestCount, 0)
        XCTAssertFalse(vm.isInstallingUpdate)
    }

    // Релиз без .pkg демон установить не может: раньше баннер обещал установку
    // в один клик, а демон отвечал отказом уже после нажатия.
    func test_release_without_a_package_does_not_ask_the_daemon() async {
        let installer = StubInstaller(.started)
        let opener = SpyURLOpener()
        let vm = UpdateVM(
            fetcher: CountingFetcher(payload: releaseWithoutPackage(tag: "v9.9.9")),
            opener: opener,
            installer: installer,
            currentVersion: "1.0.0"
        )
        await vm.checkForUpdateAndWait()
        XCTAssertNotNil(vm.availableUpdate, "о новой версии сообщить всё равно надо")

        vm.primaryAction()

        XCTAssertEqual(installer.requestCount, 0, "root не о чем просить — пакета нет")
        XCTAssertFalse(vm.isInstallingUpdate)
        XCTAssertNotNil(vm.installFailure)
        XCTAssertEqual(opener.urls.count, 1, "остаётся ручной путь — страница релиза")
    }

    // Ответ «установка начата» уходит до скачивания, поэтому провал после него
    // приходил только в unified log, а пользователь оставался со спиннером.
    func test_failure_after_the_start_reply_stops_the_spinner() async {
        let vm = makeVM(
            installer: StubInstaller(.started, lateFailure: "Не удалось скачать пакет: нет сети"),
            opener: SpyURLOpener()
        )
        await vm.checkForUpdateAndWait()
        vm.primaryAction()
        XCTAssertTrue(vm.isInstallingUpdate)

        vm.refreshInstallOutcome()
        await settle()

        XCTAssertFalse(vm.isInstallingUpdate)
        XCTAssertEqual(vm.installFailure, "Не удалось скачать пакет: нет сети")
        vm.stop()
    }

    func test_silent_daemon_keeps_the_spinner_up() async {
        let vm = makeVM(installer: StubInstaller(.started), opener: SpyURLOpener())
        await vm.checkForUpdateAndWait()
        vm.primaryAction()

        vm.refreshInstallOutcome()
        await settle()

        XCTAssertTrue(vm.isInstallingUpdate, "молчание демона — не провал, установка идёт")
        XCTAssertNil(vm.installFailure)
        vm.stop()
    }

    func test_non_github_release_url_is_not_opened() {

        XCTAssertNil(UpdateVM.validatedReleaseURL("http://github.com/squaretus/weto"))
        XCTAssertNil(UpdateVM.validatedReleaseURL("https://evil.example.com/weto"))
        XCTAssertNil(UpdateVM.validatedReleaseURL("file:///etc/passwd"))
        XCTAssertNotNil(UpdateVM.validatedReleaseURL("https://github.com/squaretus/weto/releases"))
    }
}
