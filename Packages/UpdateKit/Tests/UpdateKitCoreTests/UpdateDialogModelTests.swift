import XCTest
@testable import UpdateKitCore

final class UpdateDialogModelTests: XCTestCase {

    private let strings = UpdateStrings(appName: "Sample")

    private let info = UpdateInfo(
        currentVersion: "0.4.0",
        latestVersion: "0.4.2",
        releaseURL: "https://github.com/example/sample/releases/tag/v0.4.2",
        downloadURL: "https://github.com/example/sample/releases/download/v0.4.2/Sample.pkg",
        releaseNotes: nil,
        isNewer: true
    )

    func test_offer_names_both_versions() {
        let model = UpdateDialogModel.make(info: info, progress: .idle, strings: strings)

        XCTAssertEqual(model.title, "Доступна новая версия Sample")
        XCTAssertEqual(model.detail, "Sample 0.4.2 — у вас 0.4.0. Обновиться сейчас?")
        XCTAssertTrue(model.showsChoiceButtons)
        XCTAssertNil(model.fraction)
        XCTAssertFalse(model.showsReleasePageButton)
    }

    func test_downloading_shows_a_real_fraction() {
        let model = UpdateDialogModel.make(
            info: info,
            progress: UpdateProgress(phase: .downloading, fraction: 0.62),
            strings: strings
        )

        XCTAssertEqual(model.title, "Обновление Sample")
        XCTAssertEqual(model.detail, "Загрузка 0.4.2…")
        XCTAssertEqual(model.fraction ?? 0, 0.62, accuracy: 0.0001)
        XCTAssertFalse(model.showsChoiceButtons)
    }

    func test_installing_is_indeterminate() {
        let model = UpdateDialogModel.make(
            info: info,
            progress: UpdateProgress(phase: .installing),
            strings: strings
        )

        XCTAssertEqual(model.detail, "Установка…")
        XCTAssertNil(model.fraction, "installer прогресса не отдаёт — полосу не подделываем")
    }

    func test_failure_offers_the_release_page() {
        let model = UpdateDialogModel.make(
            info: info,
            progress: UpdateProgress(phase: .failed, failure: "Не удалось скачать пакет: нет сети"),
            strings: strings
        )

        XCTAssertEqual(model.detail, "Не удалось скачать пакет: нет сети")
        XCTAssertTrue(model.showsReleasePageButton)
        XCTAssertFalse(model.showsChoiceButtons)
    }

    /// Релиз без пакета: демону нечего ставить, зато страница релиза есть.
    func test_release_without_a_package_offers_the_page_instead_of_install() {
        let withoutPackage = UpdateInfo(
            currentVersion: "0.4.0",
            latestVersion: "0.4.2",
            releaseURL: info.releaseURL,
            downloadURL: "",
            releaseNotes: nil,
            isNewer: true
        )

        let model = UpdateDialogModel.make(info: withoutPackage, progress: .idle, strings: strings)

        XCTAssertTrue(model.showsReleasePageButton)
        XCTAssertFalse(model.canInstall)
    }
}
