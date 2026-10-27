import XCTest
@testable import WetoCLI
import WetoCore
import WetoShared
import WetoSystem

/// Вывод команды — построчно, отдельно stdout и stderr.
final class BufferOutput: CLIOutput {
    private(set) var lines: [String] = []
    private(set) var errors: [String] = []

    func out(_ line: String) { lines.append(line) }
    func err(_ line: String) { errors.append(line) }
}

/// Резолвер с заданным соответствием: что за записью стоит на диске,
/// решает граница системы, и в тесте её ответ задан.
struct StubResolver: TargetResolving {
    let mapping: [String: String]

    func resolve(_ entry: String) -> TargetRule? {
        // Абсолютный путь к существующему файлу — как у настоящего резолвера:
        // имя — последний компонент записи, путь — после разворота симлинков.
        if mapping[entry] == nil, entry.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: entry) {
            return TargetRule(entry: entry, displayName: (entry as NSString).lastPathComponent,
                              kind: .binary, path: (entry as NSString).resolvingSymlinksInPath)
        }
        guard let path = mapping[entry] else { return nil }
        // Имя — по правилу настоящего `TargetResolver`: у бандла — имя `.app`,
        // у бинарника — сама запись (у версионного пути последний компонент — номер).
        let isBundle = path.hasSuffix(".app")
        let name = isBundle
            ? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            : (entry.contains("/") ? (entry as NSString).lastPathComponent : entry)
        return TargetRule(entry: entry, displayName: name,
                          kind: isBundle ? .appBundle : .binary, path: path)
    }
}

struct StubInterfaces: InterfaceListing {
    let interfaces: [RaisedInterface]
    /// Опущенные интерфейсы: есть в системе, но не подняты.
    var lowered: [String] = []
    func raisedInterfaces() -> [RaisedInterface] { interfaces }
    func interfaceNames() -> [String] { (interfaces.map(\.name) + lowered).sorted() }
}

struct StubSnapshotReader: NetworkSnapshotReading {
    let value: NetworkSnapshot
    func snapshot() -> NetworkSnapshot { value }
}

/// `launchctl` без launchd: запоминает вызовы и отвечает заданным.
final class SpyLaunchctl: ServiceControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String]] = []
    /// По умолчанию задание не загружено: `print` отвечает, как launchd о незнакомом.
    var answers: [String: (Int32, String)] = ["print": (113, "Could not find service")]

    var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        lock.lock()
        stored.append(arguments)
        let answer = answers[arguments.first ?? ""]
        lock.unlock()
        return answer.map { (status: $0.0, output: $0.1) } ?? (status: 0, output: "")
    }
}

final class StubGuardProcess: GuardProcessSignaling, @unchecked Sendable {
    var alive: Set<Int32> = []
    private(set) var checksRequested: [Int32] = []

    func isAlive(_ pid: Int32) -> Bool { alive.contains(pid) }
    func requestCheck(_ pid: Int32) -> Bool {
        checksRequested.append(pid)
        return alive.contains(pid)
    }
}

struct StubAppDetector: WetoAppDetecting {
    var isWetoAppRunning: Bool
}

struct EmptyLocator: ProcessLocating {
    func bundlePath(forBundleID bundleID: String) -> String? { nil }
    func allProcesses(includeArguments: Bool) -> [ProcessSnapshot] { [] }
}

/// GitHub без сети: ответы по адресам, запросы запоминаются вместе с заголовками.
final class FakeReleaseServer: HTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: Data] = [:]
    private var stored: [(url: String, headers: [String: String])] = []
    /// Ответить 404 на запрос релиза — у репозитория без единого релиза так и есть.
    var noReleases = false

    var requests: [(url: String, headers: [String: String])] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func serve(_ url: String, _ data: Data) {
        lock.lock(); responses[url] = data; lock.unlock()
    }

    func fetch(from url: URL, headers: [String: String]) async throws -> HTTPResponse {
        lock.lock()
        stored.append((url.absoluteString, headers))
        let data = responses[url.absoluteString]
        let missing = noReleases
        lock.unlock()
        if missing {
            let response = HTTPResponse(data: Data("{\"message\":\"Not Found\"}".utf8), statusCode: 404, duration: 0)
            throw HTTPFetchError(statusCode: 404, response: response)
        }
        guard let data else { throw URLError(.cannotFindHost) }
        return HTTPResponse(data: data, statusCode: 200, duration: 0)
    }

    static let latestURL = "https://api.github.com/repos/squaretus/weto/releases/latest"

    /// Релиз с ассетами по точным именам; `nil` у ссылки — ассета нет.
    func publish(version: String, archive: Data?, sums: String?, assetHost: String = "github.com") {
        let name = "weto-cli-\(version)-macos-arm64.tar.gz"
        var assets: [[String: String]] = []
        let base = "https://\(assetHost)/squaretus/weto/releases/download/v\(version)"
        if let archive {
            assets.append(["name": name, "browser_download_url": "\(base)/\(name)"])
            serve("\(base)/\(name)", archive)
        }
        if let sums {
            assets.append(["name": "SHA256SUMS", "browser_download_url": "\(base)/SHA256SUMS"])
            serve("\(base)/SHA256SUMS", Data(sums.utf8))
        }
        assets.append(["name": "Weto-\(version).pkg", "browser_download_url": "\(base)/Weto-\(version).pkg"])
        let body: [String: Any] = ["tag_name": "v\(version)", "assets": assets]
        serve(Self.latestURL, try! JSONSerialization.data(withJSONObject: body))
    }
}

/// `PATH` пользователя без su: что ответил бы его логин-шелл и где его дом.
final class FakeUserPaths: UserSearchPathProviding, @unchecked Sendable {
    /// `nil` — шелл промолчал.
    var shellPath: [String]?
    var home: String?
    private(set) var askedFor: [String] = []

    func loginShellPath(ofUser user: String) -> [String]? {
        askedFor.append(user)
        return shellPath
    }
    func homeDirectory(ofUser user: String) -> String? { home }
}

/// Архив без `tar`: «архив» — это сам бинарник, распаковка возвращает его как есть.
struct PassthroughUnpacker: ArchiveUnpacking {
    func singleFile(named name: String, inTarGz archive: Data) -> Result<Data, BoundaryFailure> {
        .success(archive)
    }
}

/// Замена бинарника без файловой системы: что и куда легло бы.
final class SpyReplacer: ExecutableReplacing, @unchecked Sendable {
    var writable = true
    private(set) var replaced: [(path: String, contents: Data)] = []

    func canReplace(_ path: String) -> Bool { writable }
    func replace(_ path: String, with contents: Data) -> Result<Void, BoundaryFailure> {
        replaced.append((path, contents))
        return .success(())
    }
}

actor FixedProbe: GeoProbing {
    let report: GeoProbeReport
    init(_ report: GeoProbeReport) { self.report = report }
    func probe() async -> GeoProbeReport { report }
}

/// Временный дом CLI: свой набор настроек и свой каталог данных на каждый тест.
@MainActor
final class CLIHarness {
    let home: URL
    let suiteName: String
    let defaults: UserDefaults
    let userPaths: CLIPaths
    let systemPaths: CLIPaths
    var paths: CLIPaths { isRoot ? systemPaths : userPaths }
    let output = BufferOutput()
    let launchctl = SpyLaunchctl()
    let guardProcess = StubGuardProcess()
    let releases = FakeReleaseServer()
    let replacer = SpyReplacer()
    var version = "0.2.0"
    /// Охрана от root: тест — либо сам root (`isRoot`), либо пользователь рядом с ней.
    var isRoot = false
    var sudoUID: uid_t?
    var sudoUser: String?
    let callerPaths = FakeUserPaths()
    /// Аргументы как введены — их `run` кладёт в окружение, как точка входа.
    var arguments: [String] = []
    var lowered: [String] = []
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var interfaces: [RaisedInterface] = [
        RaisedInterface(name: "en0", addresses: ["192.168.0.100"]),
        RaisedInterface(name: "utun6", addresses: ["198.18.0.1"]),
    ]
    var outgoing: OutgoingRoute? = OutgoingRoute(interface: "utun6", address: "198.18.0.1")
    var stdinLine: String?
    var probeReport = GeoProbeReport(
        ip: "203.0.113.28", ipinfo: .answered("KZ"), confirmation: .answered("KZ"),
        confirmSource: .freeipapi, hasNetworkPath: true, checkedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let resolver = StubResolver(mapping: [
        "claude": "/Users/me/.local/share/claude/versions/2.1.228",
        "su.ffg.happ": "/Applications/Happ.app",
    ])

    lazy var settings = SettingsStore(defaults: defaults, secrets: FileSecretStore(directory: paths.dataDirectory))

    init() {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("weto-cli-tests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "com.weto.cli.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        userPaths = CLIPaths.user(home: home)
        systemPaths = CLIPaths.system(root: home.appendingPathComponent("root", isDirectory: true))
    }

    func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: home)
    }

    var cli: CLI {
        let snapshot = NetworkSnapshot(outgoing: outgoing, upInterfaces: interfaces.map(\.name))
        let report = probeReport
        let line = stdinLine
        let clock = now
        return CLI(env: CLIEnvironment(
            paths: paths,
            systemPaths: systemPaths,
            settings: settings,
            resolver: resolver,
            interfaces: StubInterfaces(interfaces: interfaces, lowered: lowered),
            snapshotReader: StubSnapshotReader(value: snapshot),
            service: launchctl,
            guardProcess: guardProcess,
            appDetector: StubAppDetector(isWetoAppRunning: false),
            output: output,
            readSecretLine: { line },
            now: { clock },
            executablePath: { "/usr/local/bin/weto" },
            uid: isRoot ? 0 : 501,
            arguments: arguments,
            sudoUID: sudoUID,
            sudoUser: sudoUser,
            userPaths: callerPaths,
            version: version,
            updateSource: UpdateSource(fetcher: releases, currentVersion: version),
            unpacker: PassthroughUnpacker(),
            replacer: replacer,
            makeProbe: { _ in FixedProbe(report) },
            locator: EmptyLocator(),
            checkTimeout: 0.3,
            checkPollInterval: 0.05,
            snapshotSettleTimeout: 0
        ))
    }

    @discardableResult
    func run(_ line: String) -> Int32 {
        arguments = line.split(separator: " ").map(String.init)
        defer { arguments = [] }
        let command = try! CommandParser.parse(arguments).get()
        return cli.execute(command)
    }

    /// Охрана от root на машине: признак — системный каталог данных.
    func installSystemGuard() {
        try! FileManager.default.createDirectory(at: systemPaths.dataDirectory, withIntermediateDirectories: true)
    }
}
