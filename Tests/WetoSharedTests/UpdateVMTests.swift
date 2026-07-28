import XCTest
@testable import WetoShared
import WetoCore
import WetoSystem

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

@MainActor
final class UpdateVMTests: XCTestCase {

    private func release(tag: String, url: String = "https://github.com/squaretus/weto/releases/tag/v9.9.9") -> Data {
        Data("""
        {"tag_name":"\(tag)","html_url":"\(url)"}
        """.utf8)
    }

    func test_available_update_opens_release_instead_of_rechecking() async {
        let fetcher = CountingFetcher(payload: release(tag: "v9.9.9"))
        let opener = SpyURLOpener()
        let vm = UpdateVM(fetcher: fetcher, opener: opener, currentVersion: "1.0.0")

        await vm.checkForUpdateAndWait()
        guard case .available(let info) = vm.state else {
            return XCTFail("ожидалось состояние .available, получено \(vm.state)")
        }

        vm.primaryAction()

        XCTAssertEqual(opener.urls.map(\.absoluteString), [info.releaseURL])
        let calls = await fetcher.count()
        XCTAssertEqual(calls, 1, "открытие релиза не должно повторно опрашивать GitHub")
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

    func test_non_github_release_url_is_not_opened() {

        XCTAssertNil(UpdateVM.validatedReleaseURL("http://github.com/squaretus/weto"))
        XCTAssertNil(UpdateVM.validatedReleaseURL("https://evil.example.com/weto"))
        XCTAssertNil(UpdateVM.validatedReleaseURL("file:///etc/passwd"))
        XCTAssertNotNil(UpdateVM.validatedReleaseURL("https://github.com/squaretus/weto/releases"))
    }
}
