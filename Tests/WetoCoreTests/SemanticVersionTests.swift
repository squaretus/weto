import XCTest
@testable import WetoCore

/// Ссылка на PKG нужна демону: он скачивает и ставит обновление сам,
/// поэтому обязан узнать адрес ассета из ответа GitHub, а не от клиента.
final class ReleaseAssetTests: XCTestCase {

    private func release(assets: String) -> Data {
        Data("""
        {"tag_name":"v1.2.0","html_url":"https://github.com/squaretus/weto/releases/tag/v1.2.0",
         "body":"описание релиза","assets":[\(assets)]}
        """.utf8)
    }

    func test_pkg_asset_url_is_extracted() throws {
        let data = release(assets: """
        {"name":"Weto-1.2.0.pkg","browser_download_url":"https://github.com/squaretus/weto/releases/download/v1.2.0/Weto-1.2.0.pkg","size":514083}
        """)

        let info = try ReleaseParser.parse(data, currentVersion: "1.0.0").get()

        XCTAssertEqual(
            info.downloadURL,
            "https://github.com/squaretus/weto/releases/download/v1.2.0/Weto-1.2.0.pkg"
        )
        XCTAssertEqual(info.releaseNotes, "описание релиза")
        XCTAssertTrue(info.isNewer)
    }

    func test_non_pkg_assets_are_ignored() throws {
        let data = release(assets: """
        {"name":"checksums.txt","browser_download_url":"https://example.com/checksums.txt","size":12},
        {"name":"Weto-1.2.0.pkg","browser_download_url":"https://github.com/squaretus/weto/releases/download/v1.2.0/Weto-1.2.0.pkg","size":1}
        """)

        let info = try ReleaseParser.parse(data, currentVersion: "1.0.0").get()
        XCTAssertTrue(info.downloadURL.hasSuffix(".pkg"))
    }

    func test_release_without_pkg_asset_has_empty_download_url() throws {

        let info = try ReleaseParser.parse(release(assets: ""), currentVersion: "1.0.0").get()
        XCTAssertTrue(info.downloadURL.isEmpty, "ставить нечего — демон обязан отказаться")
    }

    func test_missing_assets_key_is_tolerated() throws {
        let data = Data(#"{"tag_name":"v1.2.0"}"#.utf8)
        let info = try ReleaseParser.parse(data, currentVersion: "1.0.0").get()
        XCTAssertTrue(info.downloadURL.isEmpty)
        XCTAssertNil(info.releaseNotes)
    }
}

final class SemanticVersionTests: XCTestCase {

    func test_parses_three_component_version() {
        let version = SemanticVersion(string: "1.2.3")
        XCTAssertEqual(version?.major, 1)
        XCTAssertEqual(version?.minor, 2)
        XCTAssertEqual(version?.patch, 3)
    }

    func test_missing_components_default_to_zero() {
        XCTAssertEqual(SemanticVersion(string: "2"), SemanticVersion(string: "2.0.0"))
        XCTAssertEqual(SemanticVersion(string: "2.5"), SemanticVersion(string: "2.5.0"))
    }

    func test_ordering_is_by_component_significance() {
        XCTAssertTrue(SemanticVersion(string: "1.0.0")! < SemanticVersion(string: "1.0.1")!)
        XCTAssertTrue(SemanticVersion(string: "1.9.9")! < SemanticVersion(string: "1.10.0")!)
        XCTAssertTrue(SemanticVersion(string: "1.10.0")! < SemanticVersion(string: "2.0.0")!)
    }

    func test_malformed_input_returns_nil() {
        XCTAssertNil(SemanticVersion(string: ""))
        XCTAssertNil(SemanticVersion(string: "версия"))
        XCTAssertNil(SemanticVersion(string: "1.x.3"))
        XCTAssertNil(SemanticVersion(string: "1.2.3.4"))
    }
}

final class ReleaseParserTests: XCTestCase {

    private func releaseJSON(tag: String) -> Data {
        Data("""
        {"tag_name":"\(tag)","html_url":"https://github.com/o/r/releases/tag/\(tag)"}
        """.utf8)
    }

    func test_newer_tag_is_reported_as_update() throws {
        let info = try ReleaseParser.parse(releaseJSON(tag: "v1.1.0"), currentVersion: "1.0.0").get()
        XCTAssertTrue(info.isNewer)
        XCTAssertEqual(info.latestVersion, "1.1.0")
        XCTAssertEqual(info.releaseURL, "https://github.com/o/r/releases/tag/v1.1.0")
    }

    func test_tag_without_v_prefix_is_accepted() throws {
        let info = try ReleaseParser.parse(releaseJSON(tag: "1.1.0"), currentVersion: "1.0.0").get()
        XCTAssertEqual(info.latestVersion, "1.1.0")
    }

    func test_same_and_older_versions_are_not_updates() throws {
        let same = try ReleaseParser.parse(releaseJSON(tag: "v1.0.0"), currentVersion: "1.0.0").get()
        XCTAssertFalse(same.isNewer)
        let older = try ReleaseParser.parse(releaseJSON(tag: "v0.9.0"), currentVersion: "1.0.0").get()
        XCTAssertFalse(older.isNewer)
    }

    func test_malformed_tag_fails() {
        guard case .failure = ReleaseParser.parse(releaseJSON(tag: "релиз"), currentVersion: "1.0.0")
        else { return XCTFail("нечитаемый тег должен приводить к ошибке") }
    }

    func test_latest_release_url_points_at_configured_repository() {
        XCTAssertEqual(
            ReleaseParser.latestReleaseURL,
            "https://api.github.com/repos/\(Constants.githubOwner)/\(Constants.githubRepo)/releases/latest"
        )
    }
}
