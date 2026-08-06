import XCTest
@testable import WetoDesign

/// Ресурсы дизайн-системы должны находиться без обращения к `Bundle.module`:
/// тот ищет бандл только в корне `Bundle.main` и в пути машины сборки, из-за чего
/// приложение падало у пользователя, а подпись бандла становилась невозможной.
@MainActor
final class DesignResourcesTests: XCTestCase {

    func test_resource_bundle_resolves() {
        XCTAssertFalse(DesignResources.bundle.bundlePath.isEmpty)
    }

    func test_brand_assets_are_found() {
        XCTAssertNotNil(DesignResources.url(forResource: "cli-codex.png"))
        XCTAssertNotNil(DesignResources.url(forResource: "cli-claude.svg"))
    }

    func test_unknown_resource_returns_nil() {
        XCTAssertNil(DesignResources.url(forResource: "нет-такого-файла.png"))
    }

    /// Иконка приложения меняется вместе с темой, поэтому в ресурсах лежат обе:
    /// пропавший файл иначе тихо превратился бы в системную иконку-заглушку.
    func test_app_icon_exists_for_both_themes() {
        XCTAssertNotNil(WetoAppIcon.nsImage(for: .dark))
        XCTAssertNotNil(WetoAppIcon.nsImage(for: .light))
    }

    func test_app_icon_differs_between_themes() {
        XCTAssertNotEqual(
            WetoAppIcon.nsImage(for: .dark)?.tiffRepresentation,
            WetoAppIcon.nsImage(for: .light)?.tiffRepresentation
        )
    }

    func test_known_brand_icons_render() {
        let store = TargetIconStore()

        XCTAssertNotNil(store.icon(for: .commandLine(name: "codex"), size: 22))
        XCTAssertNotNil(store.icon(for: .commandLine(name: "claude"), size: 22))
    }
}
