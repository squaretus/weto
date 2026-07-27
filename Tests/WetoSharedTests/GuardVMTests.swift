import XCTest
@testable import WetoShared
import WetoCore
import WetoSystem

private struct StubSnapshotReader: NetworkSnapshotReading {
    let snapshotValue: NetworkSnapshot
    func snapshot() -> NetworkSnapshot { snapshotValue }
}

private actor StubGeoProbe: GeoProbing {
    private let outcome: GeoOutcome
    private var callCount = 0

    init(_ outcome: GeoOutcome) { self.outcome = outcome }

    func probe() async -> GeoOutcome {
        callCount += 1
        return outcome
    }

    func calls() -> Int { callCount }
}

private struct StubLocator: ProcessLocating {
    let bundlePaths: [String: String]
    let processes: [ProcessSnapshot]

    func bundlePath(forBundleID bundleID: String) -> String? { bundlePaths[bundleID] }
    func allProcesses(includeArguments: Bool) -> [ProcessSnapshot] { processes }
}

private final class MutableLocator: ProcessLocating, @unchecked Sendable {
    let bundlePaths: [String: String]
    var processes: [ProcessSnapshot]

    init(bundlePaths: [String: String], processes: [ProcessSnapshot]) {
        self.bundlePaths = bundlePaths
        self.processes = processes
    }

    func bundlePath(forBundleID bundleID: String) -> String? { bundlePaths[bundleID] }
    func allProcesses(includeArguments: Bool) -> [ProcessSnapshot] { processes }
}

private struct StubResolver: TargetResolving {
    let mapping: [String: String]

    func resolve(_ entry: String) -> TargetRule? {
        guard let path = mapping[entry] else { return nil }
        let kind: TargetKind = path.hasSuffix(".app")
            ? .appBundle
            : (path.hasSuffix(".js") ? .script : .binary)
        return TargetRule(entry: entry, displayName: entry, kind: kind, path: path)
    }
}

private final class SpyKiller: ProcessKilling, @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [[Int32]] = []
    private var errors: [Int32: Int32] = [:]

    var killedBatches: [[Int32]] {
        lock.lock(); defer { lock.unlock() }
        return batches
    }

    func setError(_ code: Int32, forPID pid: Int32) {
        lock.lock(); errors[pid] = code; lock.unlock()
    }

    func kill(pids: [Int32]) -> [KillResult] {
        lock.lock()
        batches.append(pids)
        let snapshot = errors
        lock.unlock()
        return pids.map { KillResult(pid: $0, errorCode: snapshot[$0]) }
    }
}

private final class SpyNotifier: KillNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var messages: [String] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
    func notify(reasonText: String, killedCount: Int) {
        lock.lock(); stored.append(reasonText); lock.unlock()
    }
}

private final class ManualEventSource: NetworkEventSourcing, @unchecked Sendable {
    private(set) var stopped = false
    private var handler: (@Sendable (GuardTrigger) -> Void)?

    func start(handler: @escaping @Sendable (GuardTrigger) -> Void) { self.handler = handler }
    func stop() { stopped = true; handler = nil }
    var isListening: Bool { handler != nil }
}

@MainActor
final class GuardVMTests: XCTestCase {

    private let targetBundleID = "com.example.target"
    private let targetPath = "/Applications/Target.app"

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "com.weto.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    private func healthySnapshot() -> NetworkSnapshot {
        NetworkSnapshot(
            services: [
                .init(uuid: "WIFI", name: "Wi-Fi", activeInterface: "en0"),
                .init(uuid: "HAPP", name: "Happ", activeInterface: "utun6"),
            ],
            primaryServiceUUID: "HAPP"
        )
    }

    private func vpnDownSnapshot() -> NetworkSnapshot {
        NetworkSnapshot(
            services: [
                .init(uuid: "WIFI", name: "Wi-Fi", activeInterface: "en0"),
                .init(uuid: "HAPP", name: "Happ", activeInterface: nil),
            ],
            primaryServiceUUID: "WIFI"
        )
    }

    private func geoOutcome(primary: String = "KZ", confirmed: String? = "KZ") -> GeoOutcome {
        .resolved(GeoReading(
            ip: "203.0.113.28",
            primaryCountry: primary,
            confirmedCountry: confirmed,
            confirmSource: confirmed == nil ? nil : .ipwhois
        ))
    }

    private struct Harness {
        let vm: GuardVM
        let killer: SpyKiller
        let probe: StubGeoProbe
        let notifier: SpyNotifier
        let events: ManualEventSource
        let settings: SettingsStore
        let log: EventLogStore
    }

    private func makeHarness(
        snapshot: NetworkSnapshot,
        geo: GeoOutcome,
        enabled: Bool = true,
        processes: [ProcessSnapshot]? = nil,
        executables: [String] = []
    ) -> Harness {
        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        settings.isEnabled = enabled
        settings.vpnServiceName = "Happ"
        settings.blockedCountryCodes = ["RU"]
        settings.targets = [targetBundleID]
        settings.targets += executables

        let killer = SpyKiller()
        let probe = StubGeoProbe(geo)
        let notifier = SpyNotifier()
        let events = ManualEventSource()
        let log = EventLogStore(defaults: defaults)

        let vm = GuardVM(
            settings: settings,
            eventLog: log,
            snapshotReader: StubSnapshotReader(snapshotValue: snapshot),
            geoProbe: probe,
            locator: StubLocator(
                bundlePaths: [targetBundleID: targetPath],
                processes: processes ?? [
                    .init(pid: 500, executablePath: "\(targetPath)/Contents/MacOS/Target"),
                    .init(pid: 501, executablePath: "\(targetPath)/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"),
                    .init(pid: 900, executablePath: "/Applications/Other.app/Contents/MacOS/Other"),
                ]
            ),
            resolver: StubResolver(mapping: [
                targetBundleID: targetPath,
                "nano": "/usr/bin/pico",
                "qwen": "/opt/homebrew/lib/qwen/cli.js",
            ]),
            killer: killer,
            notifier: notifier,
            events: events,
            debounceInterval: 0.01
        )

        return Harness(vm: vm, killer: killer, probe: probe, notifier: notifier,
                       events: events, settings: settings, log: log)
    }

    func test_vpn_down_kills_targets_without_probing_network() async {
        let h = makeHarness(snapshot: vpnDownSnapshot(), geo: geoOutcome())

        h.vm.handle(.networkPath)

        XCTAssertEqual(h.vm.state, .unsafe(.vpnDown))
        XCTAssertEqual(h.killer.killedBatches, [[500, 501]], "убиты только процессы цели")
        let probeCalls = await h.probe.calls()
        XCTAssertEqual(probeCalls, 0, "сетевая проба не должна была запускаться")
    }

    func test_vpn_not_primary_kills() async {
        let snapshot = NetworkSnapshot(
            services: [
                .init(uuid: "WIFI", name: "Wi-Fi", activeInterface: "en0"),
                .init(uuid: "HAPP", name: "Happ", activeInterface: "utun6"),
            ],
            primaryServiceUUID: "WIFI"
        )
        let h = makeHarness(snapshot: snapshot, geo: geoOutcome())

        h.vm.handle(.networkPath)

        XCTAssertEqual(h.vm.state, .unsafe(.vpnNotPrimary))
    }

    func test_disabled_guard_never_kills() async {
        let h = makeHarness(snapshot: vpnDownSnapshot(), geo: geoOutcome(), enabled: false)

        h.vm.handle(.networkPath)

        XCTAssertEqual(h.vm.state, .disabled)
        XCTAssertTrue(h.killer.killedBatches.isEmpty)
    }

    func test_healthy_network_leads_to_safe_state_without_killing() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome())

        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()

        XCTAssertEqual(h.vm.state, .safe(h.vm.lastReading))
        XCTAssertTrue(h.killer.killedBatches.isEmpty)
        XCTAssertEqual(h.vm.lastReading?.ip, "203.0.113.28")
        XCTAssertEqual(h.vm.state.statusColor, .green)
        XCTAssertEqual(h.vm.currentCountryCode, "KZ")
    }

    func test_blocked_country_kills_and_records_event() async {
        let h = makeHarness(
            snapshot: healthySnapshot(),
            geo: geoOutcome(primary: "RU", confirmed: "RU")
        )

        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()

        XCTAssertEqual(h.vm.state, .unsafe(.blockedCountry(code: "RU", source: "ipinfo")))
        XCTAssertEqual(h.killer.killedBatches, [[500, 501]])
        XCTAssertEqual(h.log.events.count, 1)
        XCTAssertEqual(h.log.events.first?.country, "RU")
        XCTAssertEqual(h.notifier.messages.count, 1)
    }

    func test_missing_confirmation_kills_and_shows_yellow() async {
        let h = makeHarness(
            snapshot: healthySnapshot(),
            geo: geoOutcome(primary: "KZ", confirmed: nil)
        )

        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()

        XCTAssertEqual(h.vm.state, .unsafe(.confirmationUnavailable))
        XCTAssertEqual(h.vm.state.statusColor, .yellow)
        XCTAssertFalse(h.killer.killedBatches.isEmpty, "жёлтый — тоже убийство")
    }

    func test_geo_unavailable_kills_and_shows_yellow_without_flag() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: .unavailable("timeout"))

        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()

        XCTAssertEqual(h.vm.state, .unsafe(.geoUnavailable("timeout")))
        XCTAssertEqual(
            h.vm.state.statusColor, .yellow,
            "отказ ipinfo — деградация сервиса, а не блокировка: цели всё равно завершены"
        )
        XCTAssertFalse(h.killer.killedBatches.isEmpty, "жёлтый — тоже убийство")
        XCTAssertNil(h.vm.currentCountryCode)
    }

    func test_burst_of_events_collapses_into_single_probe() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome())

        for _ in 0..<10 { h.vm.handle(.networkPath) }
        await h.vm.awaitPendingProbe()

        let calls = await h.probe.calls()
        XCTAssertEqual(calls, 1, "пачка событий должна схлопнуться в одну пробу")
    }

    func test_target_relaunch_while_unsafe_is_killed_again() async {
        let h = makeHarness(snapshot: vpnDownSnapshot(), geo: geoOutcome())
        h.vm.handle(.networkPath)
        XCTAssertEqual(h.killer.killedBatches.count, 1)

        h.vm.handle(.appLaunched(bundleID: targetBundleID))

        XCTAssertEqual(h.killer.killedBatches.count, 2, "перезапущенная цель должна быть добита")
        XCTAssertEqual(h.log.events.count, 1, "те же pid повторно в журнал не пишутся")
    }

    func test_newly_launched_target_is_recorded_even_while_already_unsafe() async {

        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        settings.isEnabled = true
        settings.vpnServiceName = "Happ"
        settings.targets = [targetBundleID]

        let killer = SpyKiller()
        let log = EventLogStore(defaults: defaults)
        let locator = MutableLocator(
            bundlePaths: [targetBundleID: targetPath],
            processes: [.init(pid: 500, executablePath: "\(targetPath)/Contents/MacOS/Target")]
        )

        let vm = GuardVM(
            settings: settings,
            eventLog: log,
            snapshotReader: StubSnapshotReader(snapshotValue: vpnDownSnapshot()),
            geoProbe: StubGeoProbe(geoOutcome()),
            locator: locator,
            resolver: StubResolver(mapping: [targetBundleID: targetPath]),
            killer: killer,
            notifier: SpyNotifier(),
            events: ManualEventSource(),
            debounceInterval: 0.01
        )

        vm.handle(.networkPath)
        XCTAssertEqual(log.events.count, 1)

        locator.processes = [.init(pid: 777, executablePath: "\(targetPath)/Contents/MacOS/Target")]
        vm.handle(.tick)

        XCTAssertEqual(log.events.count, 2, "новый pid обязан попасть в журнал")
        XCTAssertEqual(log.events.first?.killedPIDs, [777])
    }

    func test_launch_of_unrelated_app_is_ignored() async {
        let h = makeHarness(snapshot: vpnDownSnapshot(), geo: geoOutcome())
        h.vm.handle(.networkPath)

        h.vm.handle(.appLaunched(bundleID: "com.apple.TextEdit"))

        XCTAssertEqual(h.killer.killedBatches.count, 1)
    }

    func test_eperm_is_surfaced_instead_of_being_swallowed() async {
        let h = makeHarness(snapshot: vpnDownSnapshot(), geo: geoOutcome())
        h.killer.setError(EPERM, forPID: 500)

        h.vm.handle(.networkPath)

        XCTAssertNotNil(h.vm.permissionFailure)
        XCTAssertTrue(h.vm.permissionFailure?.contains("500") == true)
    }

    func test_no_targets_running_does_not_produce_an_event() async {
        let h = makeHarness(
            snapshot: vpnDownSnapshot(),
            geo: geoOutcome(),
            processes: [.init(pid: 900, executablePath: "/Applications/Other.app/Contents/MacOS/Other")]
        )

        h.vm.handle(.networkPath)

        XCTAssertTrue(h.killer.killedBatches.isEmpty)
        XCTAssertTrue(h.log.events.isEmpty)
        XCTAssertEqual(h.vm.state, .unsafe(.vpnDown), "состояние всё равно небезопасное")
    }

    func test_symlinked_command_is_matched_by_resolved_path() async {

        let h = makeHarness(
            snapshot: vpnDownSnapshot(),
            geo: geoOutcome(),
            processes: [
                .init(pid: 700, executablePath: "/usr/bin/pico"),
                .init(pid: 701, executablePath: "/usr/bin/vim"),
            ],
            executables: ["nano"]
        )

        h.vm.handle(.networkPath)

        XCTAssertEqual(h.killer.killedBatches, [[700]], "убит pico, vim не тронут")
    }

    func test_script_target_is_matched_by_command_line_not_by_interpreter() async {

        let h = makeHarness(
            snapshot: vpnDownSnapshot(),
            geo: geoOutcome(),
            processes: [
                .init(pid: 800, executablePath: "/opt/homebrew/bin/node",
                      arguments: "node /opt/homebrew/lib/qwen/cli.js chat"),
                .init(pid: 801, executablePath: "/opt/homebrew/bin/node",
                      arguments: "node /Users/me/other-project/server.js"),
            ],
            executables: ["qwen"]
        )

        h.vm.handle(.networkPath)

        XCTAssertEqual(h.killer.killedBatches, [[800]], "посторонний Node-процесс не тронут")
    }

    func test_unknown_command_matches_nothing() async {
        let h = makeHarness(
            snapshot: vpnDownSnapshot(),
            geo: geoOutcome(),
            processes: [.init(pid: 700, executablePath: "/usr/bin/pico")],
            executables: ["не-существует"]
        )

        h.vm.handle(.networkPath)

        XCTAssertTrue(h.killer.killedBatches.isEmpty)
    }

    func test_executable_only_targets_still_arm_the_guard() async {

        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        settings.isEnabled = true
        settings.vpnServiceName = "Happ"
        settings.targets = []
        settings.targets = ["nano"]

        XCTAssertTrue(settings.guardConfig.hasTargets)
        XCTAssertEqual(
            GuardPolicy.decideLocal(isEnabled: true, vpn: .down, config: settings.guardConfig),
            .kill(.vpnDown)
        )
    }

    func test_first_episode_event_is_termination_second_is_launch_block() async {
        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        settings.isEnabled = true
        settings.vpnServiceName = "Happ"
        settings.targets = [targetBundleID]

        let log = EventLogStore(defaults: defaults)
        let locator = MutableLocator(
            bundlePaths: [targetBundleID: targetPath],
            processes: [.init(pid: 500, executablePath: "\(targetPath)/Contents/MacOS/Target")]
        )
        let vm = GuardVM(
            settings: settings,
            eventLog: log,
            snapshotReader: StubSnapshotReader(snapshotValue: vpnDownSnapshot()),
            geoProbe: StubGeoProbe(geoOutcome()),
            locator: locator,
            resolver: StubResolver(mapping: [targetBundleID: targetPath]),
            killer: SpyKiller(),
            notifier: SpyNotifier(),
            events: ManualEventSource(),
            debounceInterval: 0.01
        )

        vm.handle(.networkPath)
        XCTAssertEqual(log.events.first?.kind, .terminated)
        XCTAssertEqual(log.events.first?.targetNames, [targetBundleID])

        locator.processes = [.init(pid: 777, executablePath: "\(targetPath)/Contents/MacOS/Target")]
        vm.handle(.tick)
        XCTAssertEqual(log.events.first?.kind, .launchBlocked)
    }

    func test_available_vpn_names_come_from_snapshot() {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome())
        h.vm.refreshVPNNames()
        XCTAssertEqual(h.vm.availableVPNNames, ["Happ", "Wi-Fi"])
    }

    func test_running_process_count_counts_only_target_bundle() {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome())
        XCTAssertEqual(h.vm.runningProcessCount(forTarget: targetBundleID), 2)
        XCTAssertEqual(h.vm.runningProcessCount(forTarget: "com.unknown"), 0)
    }

    func test_stop_releases_the_event_source() {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome())
        h.vm.start()
        XCTAssertTrue(h.events.isListening)
        h.vm.stop()
        XCTAssertTrue(h.events.stopped)
    }
}
