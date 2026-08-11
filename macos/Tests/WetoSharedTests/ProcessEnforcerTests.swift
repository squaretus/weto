import XCTest
@testable import WetoShared
import WetoCore
import WetoSystem

/// Резолвер, чей ответ меняется между вызовами: так выглядит обновление цели,
/// когда симлинк в PATH начинает указывать на новую версию бинарника.
private final class MutableResolver: TargetResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var mapping: [String: String]
    private var calls = 0

    init(_ mapping: [String: String]) { self.mapping = mapping }

    func point(_ entry: String, to path: String?) {
        lock.lock(); mapping[entry] = path; lock.unlock()
    }

    var resolveCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    func resolve(_ entry: String) -> TargetRule? {
        lock.lock()
        calls += 1
        let path = mapping[entry]
        lock.unlock()

        guard let path else { return nil }
        return TargetRule(
            entry: entry,
            displayName: (entry as NSString).lastPathComponent,
            kind: .binary,
            path: path,
            launchPaths: [entry]
        )
    }
}

private final class MutableProcessLocator: ProcessLocating, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ProcessSnapshot]

    init(_ processes: [ProcessSnapshot]) { self.stored = processes }

    func replace(with processes: [ProcessSnapshot]) {
        lock.lock(); stored = processes; lock.unlock()
    }

    func bundlePath(forBundleID bundleID: String) -> String? { nil }

    func allProcesses(includeArguments: Bool) -> [ProcessSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

private final class SilentKiller: ProcessKilling, @unchecked Sendable {
    func kill(pids: [Int32]) -> [KillResult] { pids.map { KillResult(pid: $0, errorCode: nil) } }
}

/// Часы под управлением теста: обновление правил привязано ко времени,
/// а не к числу обходов процессов.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000_000)

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock(); value = value.addingTimeInterval(interval); lock.unlock()
    }
}

@MainActor
final class ProcessEnforcerTests: XCTestCase {

    private let entry = "/Users/me/.local/bin/claude"
    private let oldVersionPath = "/Users/me/.local/share/claude/versions/2.1.227"
    private let newVersionPath = "/Users/me/.local/share/claude/versions/2.1.228"

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "com.weto.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    private func makeEnforcer(
        targets: [String],
        resolver: TargetResolving,
        locator: ProcessLocating,
        clock: TestClock
    ) -> ProcessEnforcer {
        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        settings.targets = targets
        return ProcessEnforcer(
            settings: settings,
            resolver: resolver,
            locator: locator,
            killer: SilentKiller(),
            now: { clock.now }
        )
    }

    /// Бинарник обновился, симлинк указывает на новую версию — цель обязана
    /// подтянуться сама, без повторного добавления руками.
    func test_updated_binary_is_matched_without_re_adding_the_target() {
        let clock = TestClock()
        let resolver = MutableResolver([entry: oldVersionPath])
        let locator = MutableProcessLocator([
            ProcessSnapshot(pid: 501, executablePath: oldVersionPath)
        ])
        let enforcer = makeEnforcer(
            targets: [entry],
            resolver: resolver,
            locator: locator,
            clock: clock
        )

        XCTAssertEqual(enforcer.runningTargets(in: enforcer.scan()).map(\.pid), [501])

        resolver.point(entry, to: newVersionPath)
        locator.replace(with: [ProcessSnapshot(pid: 777, executablePath: newVersionPath)])
        clock.advance(by: Constants.targetRuleRefreshSeconds)

        XCTAssertEqual(
            enforcer.runningTargets(in: enforcer.scan()).map(\.pid),
            [777],
            "процесс новой версии обязан совпасть с той же целью"
        )
    }

    /// Сеанс, запущенный до обновления, продолжает жить на прежнем бинарнике:
    /// переезд правила на новую версию не имеет права выпускать его из-под охраны.
    func test_process_from_the_previous_binary_stays_matched_after_the_update() {
        let clock = TestClock()
        let resolver = MutableResolver([entry: oldVersionPath])
        let locator = MutableProcessLocator([
            ProcessSnapshot(pid: 501, executablePath: oldVersionPath)
        ])
        let enforcer = makeEnforcer(
            targets: [entry],
            resolver: resolver,
            locator: locator,
            clock: clock
        )

        XCTAssertEqual(enforcer.runningTargets(in: enforcer.scan()).map(\.pid), [501])

        resolver.point(entry, to: newVersionPath)
        clock.advance(by: Constants.targetRuleRefreshSeconds)

        XCTAssertEqual(
            enforcer.enforce(enforcer.scan()).matched.map(\.pid),
            [501],
            "процесс прежней версии обязан завершаться и после переезда правила"
        )
    }

    /// Пока файл подменяют, цель на мгновение не разрешается ни во что.
    /// Терять на этом окне охрану живого процесса нельзя: правило держится
    /// последним известным, а не исчезает.
    func test_target_that_stopped_resolving_keeps_guarding_the_running_process() {
        let clock = TestClock()
        let resolver = MutableResolver([entry: oldVersionPath])
        let locator = MutableProcessLocator([
            ProcessSnapshot(pid: 501, executablePath: oldVersionPath)
        ])
        let enforcer = makeEnforcer(
            targets: [entry],
            resolver: resolver,
            locator: locator,
            clock: clock
        )

        XCTAssertEqual(enforcer.runningTargets(in: enforcer.scan()).map(\.pid), [501])

        resolver.point(entry, to: nil)
        clock.advance(by: Constants.targetRuleRefreshSeconds)

        XCTAssertEqual(
            enforcer.enforce(enforcer.scan()).matched.map(\.pid),
            [501],
            "цель, переставшая разрешаться, не имеет права оставить процесс без охраны"
        )
    }

    /// Разрешение лезет в файловую систему и LaunchServices, а сторож в небезопасном
    /// состоянии обходит процессы каждые 250 мс. Внутри окна свежести правила
    /// берутся из кэша — иначе цена свежести была бы четыре разрешения в секунду.
    func test_rules_are_not_resolved_again_within_the_refresh_window() {
        let clock = TestClock()
        let resolver = MutableResolver([entry: oldVersionPath])
        let locator = MutableProcessLocator([
            ProcessSnapshot(pid: 501, executablePath: oldVersionPath)
        ])
        let enforcer = makeEnforcer(
            targets: [entry],
            resolver: resolver,
            locator: locator,
            clock: clock
        )

        _ = enforcer.scan()
        let afterFirstScan = resolver.resolveCount
        XCTAssertEqual(afterFirstScan, 1)

        clock.advance(by: Constants.targetRuleRefreshSeconds / 2)
        _ = enforcer.scan()
        _ = enforcer.scan()

        XCTAssertEqual(resolver.resolveCount, afterFirstScan)
    }
}
