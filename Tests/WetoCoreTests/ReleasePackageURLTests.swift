import XCTest
@testable import WetoCore

/// Адрес пакета приходит из сети, а качает по нему процесс с правами root.
final class ReleasePackageURLTests: XCTestCase {

    func test_github_release_asset_is_trusted() {
        XCTAssertTrue(ReleasePackageURL.isTrusted(
            "https://github.com/squaretus/weto/releases/download/v1.1.0/Weto-1.1.0.pkg"
        ))
        XCTAssertTrue(ReleasePackageURL.isTrusted(
            "https://objects.githubusercontent.com/github-production-release-asset/1/Weto-1.1.0.pkg"
        ))
    }

    func test_plain_http_is_rejected() {
        XCTAssertFalse(ReleasePackageURL.isTrusted(
            "http://github.com/squaretus/weto/releases/download/v1.1.0/Weto-1.1.0.pkg"
        ))
    }

    func test_foreign_host_is_rejected() {
        XCTAssertFalse(ReleasePackageURL.isTrusted("https://evil.example.com/Weto-1.1.0.pkg"))
        XCTAssertFalse(ReleasePackageURL.isTrusted("https://github.com.evil.example.com/w.pkg"))
    }

    func test_non_package_path_is_rejected() {
        XCTAssertFalse(ReleasePackageURL.isTrusted(
            "https://github.com/squaretus/weto/releases/download/v1.1.0/install.sh"
        ))
    }

    func test_garbage_is_rejected() {
        XCTAssertFalse(ReleasePackageURL.isTrusted(""))
        XCTAssertFalse(ReleasePackageURL.isTrusted("не адрес"))
        XCTAssertFalse(ReleasePackageURL.isTrusted("file:///tmp/weto.pkg"))
    }
}
