import XCTest
@testable import UpdateKitCore

final class UpdateFeedConfigurationTests: XCTestCase {

    private let configuration = UpdateFeedConfiguration(
        owner: "squaretus",
        repository: "weto",
        appDisplayName: "Weto",
        assetSuffix: ".pkg",
        machServiceName: "com.weto.helper",
        installedAppPath: "/Applications/Weto.app",
        clientExecutablePaths: ["/Applications/Weto.app/Contents/MacOS/WetoMenuBar"],
        debugClientExecutableSuffixes: [],
        workingDirectory: "/var/db/weto/updates",
        daemonPlistPath: "/Library/LaunchDaemons/com.weto.helper.plist",
        daemonBinaryPath: "/Library/PrivilegedHelperTools/com.weto.helper",
        logSubsystem: "com.weto.helper",
        defaultsSuite: "com.weto.shared"
    )

    func test_latest_release_url_points_at_the_repository() {
        XCTAssertEqual(
            configuration.latestReleaseURL,
            "https://api.github.com/repos/squaretus/weto/releases/latest"
        )
    }

    func test_releases_page_url_is_a_github_page() {
        XCTAssertEqual(
            configuration.releasesPageURL,
            "https://github.com/squaretus/weto/releases/latest"
        )
    }

    func test_package_path_lives_inside_the_working_directory() {
        XCTAssertEqual(configuration.packagePath, "/var/db/weto/updates/update.pkg")
    }

    /// Значения по умолчанию — час между проверками и опрос прогресса чаще,
    /// чем человек замечает рывок полосы.
    func test_default_intervals() {
        XCTAssertEqual(configuration.checkInterval, 3600)
        XCTAssertEqual(configuration.progressPollInterval, 0.4)
    }
}
