import XCTest
import UpdateKitCore
import UpdateKitXPC
@testable import UpdateKit

@MainActor
final class UpdateControllerTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func release(tag: String, withPackage: Bool = true) -> Data {
        let assets = withPackage
            ? """
              [{"name":"Sample-9.9.9.pkg",
                "browser_download_url":"https://github.com/example/sample/releases/download/v9.9.9/Sample-9.9.9.pkg"}]
              """
            : "[]"
        return Data("""
        {"tag_name":"\(tag)","html_url":"https://github.com/example/sample/releases/tag/\(tag)","assets":\(assets)}
        """.utf8)
    }

    private func makeController(
        tag: String = "v9.9.9",
        withPackage: Bool = true,
        installer: UpdateInstalling = StubInstaller(.started),
        store: MemoryStore? = nil,
        clock: FixedClock? = nil,
        opener: SpyOpener = SpyOpener()
    ) -> UpdateController {
        // Хранилище живёт на главном акторе, поэтому создаётся здесь,
        // а не значением по умолчанию: их вычисляют вне актора.
        let store = store ?? MemoryStore()

        return UpdateController(
            configuration: .testing,
            strings: UpdateStrings(appName: "Sample"),
            currentVersion: "1.0.0",
            fetcher: CountingFetcher(payload: release(tag: tag, withPackage: withPackage)),
            installer: installer,
            store: store,
            clock: clock ?? FixedClock(start),
            opener: opener
        )
    }

    /// Свежая версия без отсрочек — окно поднимается само.
    func test_found_update_presents_the_dialog() async {
        let controller = makeController()

        await controller.checkAndWait()

        XCTAssertEqual(controller.availableUpdate?.latestVersion, "9.9.9")
        XCTAssertTrue(controller.isDialogPresented)
    }

    func test_up_to_date_presents_nothing() async {
        let controller = makeController(tag: "v0.0.1")

        await controller.checkAndWait()

        XCTAssertNil(controller.availableUpdate)
        XCTAssertFalse(controller.isDialogPresented)
    }

    func test_skipped_version_stays_silent() async {
        let store = MemoryStore()
        store.deferral = UpdateDeferral(skippedVersion: "9.9.9", remindAt: nil, isAutoInstallEnabled: false)
        let controller = makeController(store: store)

        await controller.checkAndWait()

        XCTAssertFalse(controller.isDialogPresented)
        XCTAssertNil(controller.bannerUpdate, "пропуск прячет и баннер, а не только окно")
    }

    func test_skip_writes_the_version_and_closes_the_dialog() async {
        let store = MemoryStore()
        let controller = makeController(store: store)
        await controller.checkAndWait()

        controller.skipCurrentVersion()

        XCTAssertEqual(store.deferral.skippedVersion, "9.9.9")
        XCTAssertFalse(controller.isDialogPresented)
    }

    func test_remind_later_stores_an_absolute_date() async {
        let store = MemoryStore()
        let controller = makeController(store: store, clock: FixedClock(start))
        await controller.checkAndWait()

        controller.remindLater(.threeHours)

        XCTAssertEqual(store.deferral.remindAt, start.addingTimeInterval(10800))
        XCTAssertFalse(controller.isDialogPresented)
    }

    /// Закрытие окна крестиком не должно означать «больше никогда».
    func test_dismiss_equals_three_hours() async {
        let store = MemoryStore()
        let controller = makeController(store: store, clock: FixedClock(start))
        await controller.checkAndWait()

        controller.dismissDialog()

        XCTAssertEqual(store.deferral.remindAt, start.addingTimeInterval(10800))
    }

    func test_deferred_check_stays_silent_until_the_time_comes() async {
        let store = MemoryStore()
        let clock = FixedClock(start)
        let controller = makeController(store: store, clock: clock)
        await controller.checkAndWait()
        controller.remindLater(.oneHour)

        await controller.checkAndWait()
        XCTAssertFalse(controller.isDialogPresented)

        clock.advance(by: 3601)
        await controller.checkAndWait()
        XCTAssertTrue(controller.isDialogPresented)
    }

    /// Ручная проверка — единственный способ вернуть пропущенную версию.
    func test_manual_check_ignores_skip_and_reminder() async {
        let store = MemoryStore()
        store.deferral = UpdateDeferral(
            skippedVersion: "9.9.9",
            remindAt: start.addingTimeInterval(3600),
            isAutoInstallEnabled: false
        )
        let controller = makeController(store: store)

        await controller.checkNowAndWait()

        XCTAssertTrue(controller.isDialogPresented)
    }

    func test_auto_install_starts_without_a_dialog() async {
        let installer = StubInstaller(.started)
        let store = MemoryStore()
        store.deferral = UpdateDeferral(skippedVersion: nil, remindAt: nil, isAutoInstallEnabled: true)
        let controller = makeController(installer: installer, store: store)

        await controller.checkAndWait()

        XCTAssertEqual(installer.requestCount, 1)
        XCTAssertFalse(controller.isDialogPresented, "автоустановка идёт молча")
        XCTAssertTrue(controller.progress.isInFlight)
    }

    /// Тумблер в окне обязан делать ровно то, ради чего его включили.
    func test_enabling_auto_install_starts_the_pending_update() async {
        let installer = StubInstaller(.started)
        let store = MemoryStore()
        let controller = makeController(installer: installer, store: store)
        await controller.checkAndWait()

        controller.isAutoInstallEnabled = true

        XCTAssertTrue(store.deferral.isAutoInstallEnabled)
        XCTAssertEqual(installer.requestCount, 1)
    }

    func test_install_is_not_started_twice() async {
        let installer = StubInstaller(.started)
        let controller = makeController(installer: installer)
        await controller.checkAndWait()

        controller.install()
        controller.install()
        controller.install()

        XCTAssertEqual(installer.requestCount, 1)
    }

    func test_release_without_a_package_does_not_ask_the_daemon() async {
        let installer = StubInstaller(.started)
        let opener = SpyOpener()
        let controller = makeController(withPackage: false, installer: installer, opener: opener)
        await controller.checkAndWait()

        controller.install()

        XCTAssertEqual(installer.requestCount, 0, "root не о чем просить — пакета нет")
        XCTAssertEqual(opener.urls.count, 1, "остаётся ручной путь — страница релиза")
    }

    func test_missing_daemon_falls_back_to_the_release_page() async {
        let opener = SpyOpener()
        let controller = makeController(installer: StubInstaller(nil), opener: opener)
        await controller.checkAndWait()

        controller.install()
        await settle()

        XCTAssertFalse(controller.progress.isInFlight)
        XCTAssertEqual(opener.urls.count, 1)
    }

    func test_download_progress_reaches_the_ui() async {
        let installer = StubInstaller(.started, progress: UpdateProgress(phase: .downloading, fraction: 0.62))
        let controller = makeController(installer: installer)
        await controller.checkAndWait()
        controller.install()

        controller.pollProgressOnce()
        await settle()

        XCTAssertEqual(controller.progress.phase, .downloading)
        XCTAssertEqual(controller.progress.fraction, 0.62, accuracy: 0.0001)
        XCTAssertEqual(controller.dialogModel.fraction ?? 0, 0.62, accuracy: 0.0001)
    }

    func test_failure_stops_the_progress_and_is_shown() async {
        let installer = StubInstaller(.started)
        let controller = makeController(installer: installer)
        await controller.checkAndWait()
        controller.install()

        installer.setProgress(UpdateProgress(phase: .failed, failure: "Не удалось скачать пакет: нет сети"))
        controller.pollProgressOnce()
        await settle()

        XCTAssertEqual(controller.progress.phase, .failed)
        XCTAssertEqual(controller.dialogModel.detail, "Не удалось скачать пакет: нет сети")
        XCTAssertTrue(controller.dialogModel.showsReleasePageButton)
    }

    /// Молчание демона — не успех: прогресс остаётся, а не гаснет как при готовом обновлении.
    func test_silent_daemon_keeps_the_progress_up() async {
        let installer = StubInstaller(.started, progress: nil)
        let controller = makeController(installer: installer)
        await controller.checkAndWait()
        controller.install()

        controller.pollProgressOnce()
        await settle()

        XCTAssertTrue(controller.progress.isInFlight)
    }

    func test_second_start_does_not_create_a_second_loop() async {
        let fetcher = CountingFetcher(payload: release(tag: "v0.0.1"))
        let controller = UpdateController(
            configuration: .testing,
            strings: UpdateStrings(appName: "Sample"),
            currentVersion: "1.0.0",
            fetcher: fetcher,
            installer: StubInstaller(.started),
            store: MemoryStore(),
            clock: FixedClock(start),
            opener: SpyOpener()
        )

        controller.start()
        controller.start()
        controller.start()
        await controller.checkAndWait()

        let calls = await fetcher.count()
        XCTAssertEqual(calls, 1, "повторный старт не должен множить проверки")
        controller.stop()
    }

    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }
}
