import XCTest
import UpdateKitCore

/// Баннер в попапе показывает те же фазы, что и окно: одно место решает,
/// как звучит каждая фаза. Тест закрепляет то, что видит пользователь.
final class UpdateBannerTextTests: XCTestCase {

    private let strings = UpdateStrings(appName: "Weto")

    func test_idle_announces_the_version() {
        XCTAssertEqual(strings.bannerProgress(.idle, version: "0.4.2"), "Доступно обновление 0.4.2")
    }

    func test_downloading_shows_percent() {
        let text = strings.bannerProgress(
            UpdateProgress(phase: .downloading, fraction: 0.62),
            version: "0.4.2"
        )
        XCTAssertEqual(text, "Загрузка 0.4.2… 62 %")
    }

    func test_installing_has_no_percent() {
        XCTAssertEqual(
            strings.bannerProgress(UpdateProgress(phase: .installing), version: "0.4.2"),
            "Установка…"
        )
    }

    func test_failure_speaks_plainly() {
        XCTAssertEqual(
            strings.bannerProgress(
                UpdateProgress(phase: .failed, failure: "Не удалось скачать пакет: нет сети"),
                version: "0.4.2"
            ),
            "Не удалось скачать пакет: нет сети"
        )
    }
}
