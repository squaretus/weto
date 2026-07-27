import XCTest
@testable import WetoCore

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

    private func releaseJSON(tag: String, asset: String? = "Weto-1.1.0.pkg") -> Data {
        let assets = asset.map {
            #"[{"name":"\#($0)","browser_download_url":"https://example.com/\#($0)"}]"#
        } ?? "[]"
        return Data("""
        {"tag_name":"\(tag)","body":"Исправлены ошибки",
         "html_url":"https://github.com/o/r/releases/tag/\(tag)","assets":\(assets)}
        """.utf8)
    }

    func test_newer_tag_is_reported_as_update() throws {
        let info = try ReleaseParser.parse(releaseJSON(tag: "v1.1.0"), currentVersion: "1.0.0").get()
        XCTAssertTrue(info.isNewer)
        XCTAssertEqual(info.latestVersion, "1.1.0")
        XCTAssertEqual(info.downloadURL, "https://example.com/Weto-1.1.0.pkg")
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

    func test_release_without_installer_still_parses() throws {

        let info = try ReleaseParser.parse(
            releaseJSON(tag: "v1.1.0", asset: nil), currentVersion: "1.0.0"
        ).get()
        XCTAssertTrue(info.isNewer)
        XCTAssertTrue(info.downloadURL.isEmpty)
        XCTAssertFalse(info.releaseURL.isEmpty)
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
