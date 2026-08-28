import XCTest
@testable import UpdateKitHelper
import UpdateKitCore

/// Самоудаление демона.
final class HelperUninstallTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("updatekit-uninstall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func make(_ name: String, isDirectory: Bool = false) throws -> String {
        let url = root.appendingPathComponent(name)
        if isDirectory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try Data().write(to: url)
        }
        return url.path
    }

    /// Бандл приложения принадлежит root — его ставит установщик, — и снести его
    /// может только демон. Приложение пыталось само, упиралось в права и молчало
    /// об этом: после «удалить полностью» оно оставалось в /Applications.
    func test_the_daemon_removes_the_application_bundle_too() throws {
        let app = try make("Weto.app", isDirectory: true)
        let plist = try make("com.weto.helper.plist")
        let binary = try make("com.weto.helper")
        let working = try make("updates", isDirectory: true)

        let configuration = UpdateFeedConfiguration.testing(
            installedAppPath: app,
            workingDirectory: working,
            daemonPlistPath: plist,
            daemonBinaryPath: binary
        )
        let service = UpdaterHelperService(configuration: configuration)

        let done = expectation(description: "демон ответил")
        var failure: String?
        service.uninstallHelper { failure = $0; done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertNil(failure, "удаление прошло без отказов")
        for path in [app, plist, binary, working] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: path),
                "на диске остался \(path)"
            )
        }
    }

    /// Приложение может попросить снести и свои каталоги: права на них есть
    /// только у демона. У weto так уходит /var/db/weto, внутри которого лежит
    /// рабочий каталог, — иначе после удаления остаётся пустой каталог под root.
    func test_paths_named_by_the_host_application_are_removed_too() throws {
        let extra = try make("var-db-sample", isDirectory: true)
        let configuration = UpdateFeedConfiguration.testing(
            installedAppPath: try make("Sample.app", isDirectory: true),
            workingDirectory: try make("updates", isDirectory: true),
            daemonPlistPath: try make("com.example.helper.plist"),
            daemonBinaryPath: try make("com.example.helper"),
            additionalUninstallPaths: [extra]
        )
        let service = UpdaterHelperService(configuration: configuration)

        let done = expectation(description: "демон ответил")
        service.uninstallHelper { _ in done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertFalse(FileManager.default.fileExists(atPath: extra))
    }

    /// Чего нет — того и не удаляем: повторное удаление не должно жаловаться.
    func test_missing_paths_are_not_a_failure() throws {
        let configuration = UpdateFeedConfiguration.testing(
            installedAppPath: root.appendingPathComponent("нет.app").path,
            workingDirectory: root.appendingPathComponent("нет").path,
            daemonPlistPath: root.appendingPathComponent("нет.plist").path,
            daemonBinaryPath: root.appendingPathComponent("нет").path
        )
        let service = UpdaterHelperService(configuration: configuration)

        let done = expectation(description: "демон ответил")
        var failure: String?
        service.uninstallHelper { failure = $0; done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertNil(failure)
    }
}
