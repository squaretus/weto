import XCTest
@testable import WetoCLI
import WetoCore
import WetoSystem

/// Обновление терминальной версии против подделки GitHub: сеть, распаковка
/// и замена бинарника — границы, разбор и решение — свои.
@MainActor
final class UpdateTests: XCTestCase {

    private var h: CLIHarness!
    private let binary = Data("новый weto".utf8)

    override func setUp() async throws {
        h = CLIHarness()
    }

    override func tearDown() async throws {
        h.tearDown()
    }

    private func sums(for archive: Data, version: String = "0.3.0") -> String {
        "\(CLIUpdate.sha256Hex(Data("чужое".utf8)))  Weto-\(version).pkg\n"
            + "\(CLIUpdate.sha256Hex(archive))  weto-cli-\(version)-macos-arm64.tar.gz\n"
    }

    // MARK: - Разбор

    func test_the_asset_is_named_exactly() {
        XCTAssertEqual(CLIUpdate.assetName(version: "0.3.0"), "weto-cli-0.3.0-macos-arm64.tar.gz")
        XCTAssertEqual(CLIUpdate.latestReleaseURL.absoluteString,
                       "https://api.github.com/repos/squaretus/weto/releases/latest")
    }

    func test_checksums_are_read_as_sha256sum_prints_them() {
        let sum = String(repeating: "ab", count: 32)
        let parsed = CLIUpdate.parseChecksums("""
        \(sum)  weto-cli-0.3.0-macos-arm64.tar.gz
        \(sum.uppercased()) *Weto-0.3.0.pkg
        garbage line
        abc  short.tar.gz
        """)
        XCTAssertEqual(parsed, ["weto-cli-0.3.0-macos-arm64.tar.gz": sum, "Weto-0.3.0.pkg": sum])
    }

    func test_sha256_is_lowercase_hex() {
        XCTAssertEqual(CLIUpdate.sha256Hex(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// Только https и только хосты доставки релизов GitHub.
    func test_only_github_delivery_links_are_trusted() {
        XCTAssertTrue(CLIUpdate.isTrustedAssetURL("https://github.com/squaretus/weto/releases/download/v0.3.0/x.tar.gz"))
        XCTAssertTrue(CLIUpdate.isTrustedAssetURL("https://objects.githubusercontent.com/x"))
        XCTAssertFalse(CLIUpdate.isTrustedAssetURL("http://github.com/x.tar.gz"))
        XCTAssertFalse(CLIUpdate.isTrustedAssetURL("https://evil.example/x.tar.gz"))
        XCTAssertFalse(CLIUpdate.isTrustedAssetURL("https://github.com.evil.example/x.tar.gz"))
    }

    /// Сравнение семантическое; сборка без версии сравнивать не берётся.
    func test_versions_compare_semantically_and_unknown_builds_refuse() {
        let release = CLIRelease(version: "0.10.0", assets: [
            "weto-cli-0.10.0-macos-arm64.tar.gz": "https://github.com/x", "SHA256SUMS": "https://github.com/y",
        ])
        XCTAssertEqual(try CLIUpdate.verdict(current: "0.9.0", release: release).get(),
                       .available(current: "0.9.0", release: release))
        XCTAssertEqual(try CLIUpdate.verdict(current: "0.10.0", release: release).get(), .upToDate(current: "0.10.0"))
        XCTAssertEqual(try CLIUpdate.verdict(current: "0.11.0", release: release).get(), .upToDate(current: "0.11.0"))
        for unknown in ["dev", "0.0.0"] {
            guard case .failure(.unknownBuildVersion) = CLIUpdate.verdict(current: unknown, release: release) else {
                return XCTFail(unknown)
            }
        }
    }

    // MARK: - update check

    func test_update_check_names_both_versions() {
        h.releases.publish(version: "0.3.0", archive: binary, sums: sums(for: binary))
        XCTAssertEqual(h.run("update check"), ExitCode.success)
        XCTAssertEqual(h.output.lines, ["установлена 0.2.0, доступна 0.3.0: sudo weto update"])

        // GitHub отвечает 403 на запрос без User-Agent.
        XCTAssertEqual(h.releases.requests.first?.headers["User-Agent"], "weto/0.2.0")
        XCTAssertTrue(h.replacer.replaced.isEmpty, "check ничего не ставит")
    }

    /// Последний релиз — одно приложение (1.15.0 без CLI): новее, но ставить нечего.
    func test_a_release_without_this_platform_is_not_an_update() {
        h.releases.publish(version: "1.15.0", archive: nil, sums: nil)
        XCTAssertEqual(h.run("update check"), ExitCode.success)
        XCTAssertEqual(h.output.lines, ["в последнем релизе 1.15.0 нет терминальной версии для этой системы"])

        XCTAssertEqual(h.run("update"), ExitCode.failure)
        XCTAssertEqual(h.output.errors.last,
                       "в релизе 1.15.0 нет файла weto-cli-1.15.0-macos-arm64.tar.gz — ничего не заменено")
        XCTAssertTrue(h.replacer.replaced.isEmpty)

        var watch = UpdateWatch(startedAt: h.now)
        XCTAssertEqual(watch.record(.success(.noBuildForPlatform(current: "0.2.0", version: "1.15.0")), at: h.now), [])
        XCTAssertNil(watch.available, "работающая охрана такой релиз доступным не считает")
    }

    func test_a_repository_without_releases_says_so() {
        h.releases.noReleases = true
        XCTAssertEqual(h.run("update check"), ExitCode.failure)
        XCTAssertEqual(h.output.errors, ["не удалось проверить обновления: релизов пока нет"])
    }

    func test_update_check_on_the_latest_version() {
        h.releases.publish(version: "0.2.0", archive: binary, sums: nil)
        XCTAssertEqual(h.run("update check"), ExitCode.success)
        XCTAssertEqual(h.output.lines, ["установлена последняя версия 0.2.0"])
    }

    func test_update_check_of_an_unknown_build_goes_nowhere() {
        h.version = "dev"
        XCTAssertEqual(h.run("update check"), ExitCode.failure)
        XCTAssertEqual(h.output.errors, ["версия этой сборки неизвестна — сравнивать не с чем"])
        XCTAssertTrue(h.releases.requests.isEmpty)
    }

    func test_update_check_without_network_fails() {
        XCTAssertEqual(h.run("update check"), ExitCode.failure)
        XCTAssertTrue(h.output.errors.last?.hasPrefix("не удалось проверить обновления: ") ?? false)
    }

    // MARK: - update install

    func test_update_replaces_the_binary_and_restarts_a_running_service() {
        h.releases.publish(version: "0.3.0", archive: binary, sums: sums(for: binary))
        h.launchctl.answers["print"] = (0, "state = running\npid = 4100")

        XCTAssertEqual(h.run("update"), ExitCode.success)
        XCTAssertEqual(h.replacer.replaced.map(\.path), ["/usr/local/bin/weto"])
        XCTAssertEqual(h.replacer.replaced.first?.contents, binary)
        XCTAssertEqual(h.output.lines, ["обновлено: 0.2.0 → 0.3.0", "сервис перезапущен: com.weto.cli"])
        XCTAssertEqual(h.launchctl.calls.last, ["kickstart", "-k", "gui/501/com.weto.cli"])
    }

    func test_root_update_restarts_the_system_daemon() {
        h.isRoot = true
        h.releases.publish(version: "0.3.0", archive: binary, sums: sums(for: binary))
        h.launchctl.answers["print"] = (0, "state = running\npid = 4100")

        XCTAssertEqual(h.run("update install"), ExitCode.success)
        XCTAssertEqual(h.launchctl.calls.last, ["kickstart", "-k", "system/com.weto.cli"])
    }

    /// `sudo weto update` у пользовательской установки: LaunchDaemon нет, перезапускается
    /// LaunchAgent того, кто позвал sudo.
    func test_sudo_update_restarts_the_callers_agent_when_there_is_no_daemon() {
        h.isRoot = true
        h.sudoUID = 501
        h.releases.publish(version: "0.3.0", archive: binary, sums: sums(for: binary))
        h.launchctl.answers["print"] = (113, "Could not find service")

        XCTAssertEqual(h.run("update"), ExitCode.success)
        XCTAssertEqual(h.launchctl.calls, [["print", "system/com.weto.cli"], ["print", "gui/501/com.weto.cli"]])
        XCTAssertEqual(h.output.lines, ["обновлено: 0.2.0 → 0.3.0"])
    }

    func test_update_without_a_service_only_replaces_the_binary() {
        h.releases.publish(version: "0.3.0", archive: binary, sums: sums(for: binary))
        XCTAssertEqual(h.run("update install"), ExitCode.success)
        XCTAssertEqual(h.output.lines, ["обновлено: 0.2.0 → 0.3.0"])
        XCTAssertFalse(h.launchctl.calls.contains { $0.first == "kickstart" })
    }

    func test_update_on_the_latest_version_replaces_nothing() {
        h.releases.publish(version: "0.2.0", archive: binary, sums: sums(for: binary, version: "0.2.0"))
        XCTAssertEqual(h.run("update"), ExitCode.success)
        XCTAssertEqual(h.output.lines, ["установлена последняя версия 0.2.0"])
        XCTAssertTrue(h.replacer.replaced.isEmpty)
    }

    func test_update_without_write_access_asks_for_sudo() {
        h.releases.publish(version: "0.3.0", archive: binary, sums: sums(for: binary))
        h.replacer.writable = false
        XCTAssertEqual(h.run("update"), ExitCode.failure)
        XCTAssertEqual(h.output.errors, ["нужны права: sudo weto update"])
        XCTAssertTrue(h.replacer.replaced.isEmpty)
    }

    /// Сумма не совпала, суммы нет, ассета нет — отказ, ничего не заменено.
    func test_every_integrity_failure_replaces_nothing() {
        let cases: [(archive: Data?, sums: String?, host: String, error: String)] = [
            (binary, sums(for: Data("другое".utf8)), "github.com",
             "контрольная сумма weto-cli-0.3.0-macos-arm64.tar.gz не совпала с SHA256SUMS — ничего не заменено"),
            (binary, nil, "github.com",
             "в релизе 0.3.0 нет SHA256SUMS — без контрольной суммы ничего не заменено"),
            (binary, "\(CLIUpdate.sha256Hex(binary))  weto-cli-0.3.0-linux-x86_64.tar.gz\n", "github.com",
             "в SHA256SUMS нет суммы для weto-cli-0.3.0-macos-arm64.tar.gz — ничего не заменено"),
            (nil, sums(for: binary), "github.com",
             "в релизе 0.3.0 нет файла weto-cli-0.3.0-macos-arm64.tar.gz — ничего не заменено"),
            (binary, sums(for: binary), "evil.example",
             "ссылка на SHA256SUMS ведёт не на GitHub — ничего не заменено"),
        ]
        for (index, item) in cases.enumerated() {
            let harness = CLIHarness()
            defer { harness.tearDown() }
            harness.releases.publish(version: "0.3.0", archive: item.archive, sums: item.sums, assetHost: item.host)
            XCTAssertEqual(harness.run("update"), ExitCode.failure, "случай \(index)")
            XCTAssertEqual(harness.output.errors, [item.error], "случай \(index)")
            XCTAssertTrue(harness.replacer.replaced.isEmpty, "случай \(index)")
            XCTAssertTrue(harness.output.lines.isEmpty, "случай \(index)")
        }
    }

    // MARK: - Границы на настоящем диске

    /// Замена — запись рядом и переименование: права `0755` даже под umask root.
    func test_the_replacer_swaps_the_file_atomically_with_0755() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("weto-replace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("weto").path
        try Data("старый".utf8).write(to: URL(fileURLWithPath: path))

        let previous = umask(0o077)
        defer { umask(previous) }
        let replacer = FileExecutableReplacer()
        XCTAssertTrue(replacer.canReplace(path))
        XCTAssertNoThrow(try replacer.replace(path, with: binary).get())

        XCTAssertEqual(FileManager.default.contents(atPath: path), binary)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".weto.new").path))
        XCTAssertFalse(replacer.canReplace("/usr/bin/weto"), "в системный каталог без root не пишут")
    }

    /// В архиве обязан быть ровно один файл `weto`.
    func test_the_unpacker_takes_exactly_one_file() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("weto-tar-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try binary.write(to: directory.appendingPathComponent("weto"))
        try Data("лишнее".utf8).write(to: directory.appendingPathComponent("extra"))

        func archive(_ files: [String]) throws -> Data {
            let out = directory.appendingPathComponent("a-\(files.count).tar.gz")
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-czf", out.path, "-C", directory.path] + files
            try tar.run()
            tar.waitUntilExit()
            return try Data(contentsOf: out)
        }

        XCTAssertEqual(try TarUnpacker().singleFile(named: "weto", inTarGz: archive(["weto"])).get(), binary)
        guard case .failure = TarUnpacker().singleFile(named: "weto", inTarGz: try archive(["weto", "extra"])) else {
            return XCTFail("архив с лишним файлом не годится")
        }
        guard case .failure = TarUnpacker().singleFile(named: "weto", inTarGz: Data("не архив".utf8)) else {
            return XCTFail("не архив — не годится")
        }

        try Data().write(to: directory.appendingPathComponent("weto"))
        XCTAssertEqual(TarUnpacker().singleFile(named: "weto", inTarGz: try archive(["weto"])),
                       .failure(BoundaryFailure("файл weto пустой")))
    }

    // MARK: - Работающая охрана

    /// Через минуту после старта, потом раз в сутки; о версии — одна строка на версию,
    /// об отказах подряд — не чаще раза в сутки.
    func test_the_running_guard_announces_each_version_once() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var watch = UpdateWatch(startedAt: start)
        XCTAssertFalse(watch.isDue(at: start.addingTimeInterval(59)))
        XCTAssertTrue(watch.isDue(at: start.addingTimeInterval(60)))

        let now = start.addingTimeInterval(60)
        watch.begin(at: now)
        XCTAssertFalse(watch.isDue(at: now.addingTimeInterval(3600)))
        XCTAssertTrue(watch.isDue(at: now.addingTimeInterval(24 * 3600)))

        let release = CLIRelease(version: "0.3.0", assets: [:])
        XCTAssertEqual(watch.record(.success(.available(current: "0.2.0", release: release)), at: now),
                       ["доступна версия 0.3.0: sudo weto update"])
        XCTAssertEqual(watch.available, "0.3.0")
        XCTAssertEqual(watch.record(.success(.available(current: "0.2.0", release: release)), at: now), [])

        XCTAssertEqual(watch.record(.failure(.network("offline")), at: now),
                       ["не удалось проверить обновления: offline"])
        XCTAssertEqual(watch.record(.failure(.network("offline")), at: now.addingTimeInterval(3600)), [])
        XCTAssertEqual(watch.record(.failure(.network("offline")), at: now.addingTimeInterval(24 * 3600)).count, 1)
        XCTAssertEqual(watch.available, "0.3.0", "отказ сети не отменяет найденную версию")

        XCTAssertEqual(watch.record(.success(.upToDate(current: "0.3.0")), at: now), [])
        XCTAssertNil(watch.available)
    }
}
