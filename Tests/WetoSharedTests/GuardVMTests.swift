import XCTest
@testable import WetoShared
import WetoCore
import WetoSystem

private struct StubSnapshotReader: NetworkSnapshotReading {
    let snapshotValue: NetworkSnapshot
    func snapshot() -> NetworkSnapshot { snapshotValue }
}

/// Отчёт, чей вердикт равен заданному: тестам охраны важен именно вердикт,
/// а разбор по сервисам проверяется в `GeoProbeTests` и `StatusPresentationTests`.
private func stubReport(_ outcome: GeoOutcome) -> GeoProbeReport {
    switch outcome {
    case .resolved(let reading):
        return GeoProbeReport(
            ip: reading.ip,
            ipinfo: .answered(reading.primaryCountry),
            confirmation: reading.confirmedCountry.map { .answered($0) } ?? .failed(.unreachable),
            confirmSource: reading.confirmSource,
            hasNetworkPath: true,
            checkedAt: Date()
        )
    case .unavailable(let detail):
        return GeoProbeReport(
            ip: nil,
            ipinfo: .failed(.other(detail)),
            confirmation: .notRequested,
            confirmSource: nil,
            hasNetworkPath: true,
            checkedAt: Date()
        )
    }
}

private actor StubGeoProbe: GeoProbing {
    private let report: GeoProbeReport
    private var callCount = 0

    init(_ outcome: GeoOutcome) { self.report = stubReport(outcome) }

    func probe() async -> GeoProbeReport {
        callCount += 1
        return report
    }

    func calls() -> Int { callCount }
}

/// Проба, которую тест держит на паузе: позволяет наблюдать состояние охраны
/// именно в окне ожидания гео-вердикта и решать, какая из проб вернёт результат.
private actor DelayedGeoProbe: GeoProbing {
    private var startedCalls = 0
    private var pending: [CheckedContinuation<GeoProbeReport, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func probe() async -> GeoProbeReport {
        startedCalls += 1
        for waiter in startWaiters { waiter.resume() }
        startWaiters = []
        return await withCheckedContinuation { pending.append($0) }
    }

    func waitUntilStarted(atLeast count: Int = 1) async {
        while startedCalls < count {
            await withCheckedContinuation { startWaiters.append($0) }
        }
    }

    func resumeFirst(with outcome: GeoOutcome) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(returning: stubReport(outcome))
    }

    func starts() -> Int { startedCalls }
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

/// Считает обходы процессов и то, запрашивался ли argv.
private final class CountingLocator: ProcessLocating, @unchecked Sendable {
    let bundlePaths: [String: String]
    let processes: [ProcessSnapshot]

    private let lock = NSLock()
    private var scans = 0
    private var argumentRequests: [Bool] = []

    init(bundlePaths: [String: String], processes: [ProcessSnapshot]) {
        self.bundlePaths = bundlePaths
        self.processes = processes
    }

    func bundlePath(forBundleID bundleID: String) -> String? { bundlePaths[bundleID] }

    func allProcesses(includeArguments: Bool) -> [ProcessSnapshot] {
        lock.lock()
        scans += 1
        argumentRequests.append(includeArguments)
        lock.unlock()
        return processes
    }

    var scanCount: Int {
        lock.lock(); defer { lock.unlock() }
        return scans
    }

    var argumentsRequested: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return argumentRequests
    }
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
                .init(uuid: "WIFI", name: "Wi-Fi", activeInterface: "en0", isVPN: false),
                .init(uuid: "HAPP", name: "Happ", activeInterface: "utun6", isVPN: true),
            ],
            primaryServiceUUID: "HAPP"
        )
    }

    private func vpnDownSnapshot() -> NetworkSnapshot {
        NetworkSnapshot(
            services: [
                .init(uuid: "WIFI", name: "Wi-Fi", activeInterface: "en0", isVPN: false),
                .init(uuid: "HAPP", name: "Happ", activeInterface: nil, isVPN: true),
            ],
            primaryServiceUUID: "WIFI"
        )
    }

    private func geoOutcome(primary: String = "KZ", confirmed: String? = "KZ") -> GeoOutcome {
        .resolved(GeoReading(
            ip: "203.0.113.28",
            primaryCountry: primary,
            confirmedCountry: confirmed,
            confirmSource: confirmed == nil ? nil : .freeipapi
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
        settings.vpnServiceID = "HAPP"
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

    private struct DelayedHarness {
        let vm: GuardVM
        let killer: SpyKiller
        let probe: DelayedGeoProbe
        let settings: SettingsStore
        let log: EventLogStore
    }

    private func makeDelayedHarness(snapshot: NetworkSnapshot) -> DelayedHarness {
        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        settings.isEnabled = true
        settings.vpnServiceID = "HAPP"
        settings.blockedCountryCodes = ["RU"]
        settings.targets = [targetBundleID]

        let killer = SpyKiller()
        let probe = DelayedGeoProbe()
        let log = EventLogStore(defaults: defaults)

        let vm = GuardVM(
            settings: settings,
            eventLog: log,
            snapshotReader: StubSnapshotReader(snapshotValue: snapshot),
            geoProbe: probe,
            locator: StubLocator(
                bundlePaths: [targetBundleID: targetPath],
                processes: [
                    .init(pid: 500, executablePath: "\(targetPath)/Contents/MacOS/Target"),
                    .init(pid: 501, executablePath: "\(targetPath)/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"),
                    .init(pid: 900, executablePath: "/Applications/Other.app/Contents/MacOS/Other"),
                ]
            ),
            resolver: StubResolver(mapping: [targetBundleID: targetPath]),
            killer: killer,
            notifier: SpyNotifier(),
            events: ManualEventSource(),
            debounceInterval: 0
        )

        return DelayedHarness(vm: vm, killer: killer, probe: probe, settings: settings, log: log)
    }

    /// Даёт отменённым задачам добежать до своих проверок, не привязываясь ко времени.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func test_start_kills_targets_while_initial_probe_is_suspended() async {
        let h = makeDelayedHarness(snapshot: healthySnapshot())

        h.vm.start()
        await h.probe.waitUntilStarted()

        XCTAssertEqual(h.vm.state, .unsafe(.verificationPending))
        XCTAssertEqual(h.killer.killedBatches, [[500, 501]])
        h.vm.stop()
    }

    func test_cancelled_old_probe_cannot_restore_safe_state() async {
        let h = makeDelayedHarness(snapshot: healthySnapshot())

        h.vm.handle(.networkPath)
        await h.probe.waitUntilStarted()
        h.vm.handle(.networkPath)
        await settle()

        await h.probe.resumeFirst(with: geoOutcome())
        await settle()

        XCTAssertEqual(
            h.vm.state, .unsafe(.verificationPending),
            "результат вытесненной пробы не имеет права вернуть safe"
        )
    }

    func test_old_config_probe_result_is_ignored_after_blacklist_change() async {
        let h = makeDelayedHarness(snapshot: healthySnapshot())

        h.vm.handle(.networkPath)
        await h.probe.waitUntilStarted()

        h.settings.blockedIPRangeTexts = ["203.0.113.0/24"]
        await settle()

        await h.probe.resumeFirst(with: geoOutcome())
        await settle()

        XCTAssertEqual(h.vm.state, .unsafe(.verificationPending))
    }

    func test_adding_a_target_while_unsafe_kills_without_waiting_for_tick() {
        let h = makeHarness(
            snapshot: vpnDownSnapshot(),
            geo: geoOutcome(),
            processes: [
                .init(pid: 500, executablePath: "\(targetPath)/Contents/MacOS/Target"),
                .init(pid: 600, executablePath: "/usr/bin/pico"),
            ]
        )

        h.vm.handle(.networkPath)
        XCTAssertEqual(h.killer.killedBatches, [[500]])

        h.settings.targets = [targetBundleID, "nano"]

        XCTAssertEqual(
            h.killer.killedBatches.count, 2,
            "добавленная цель должна быть завершена сразу, а не на следующем тике"
        )
        XCTAssertEqual(h.killer.killedBatches.last, [500, 600])
    }

    func test_changing_selected_vpn_to_missing_service_kills_immediately() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome())
        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()
        XCTAssertEqual(h.vm.state, .safe(h.vm.lastReading))

        h.settings.vpnServiceID = "GHOST"

        XCTAssertEqual(h.vm.state, .unsafe(.vpnDown))
        XCTAssertFalse(h.killer.killedBatches.isEmpty)
    }

    func test_routine_tick_keeps_safe_state_while_verdict_is_fresh() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome())
        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()
        let batchesAfterFirstVerdict = h.killer.killedBatches.count

        h.vm.handle(.tick)

        XCTAssertEqual(
            h.vm.state, .safe(h.vm.lastReading),
            "штатный тик при неизменном снимке и настройках не обязан ронять цели"
        )
        await h.vm.awaitPendingProbe()
        XCTAssertEqual(h.killer.killedBatches.count, batchesAfterFirstVerdict)
    }

    func test_manual_recheck_does_not_kill_targets_on_a_healthy_vpn() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome())
        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()
        let batchesAfterFirstVerdict = h.killer.killedBatches.count

        h.vm.recheckNow()

        XCTAssertEqual(
            h.vm.state, .safe(h.vm.lastReading),
            "нажатие кнопки — не повод объявлять подключение непроверенным"
        )
        await h.vm.awaitPendingProbe()
        XCTAssertEqual(h.killer.killedBatches.count, batchesAfterFirstVerdict)
    }

    func test_manual_recheck_shows_as_running_until_the_answer_arrives() async {
        let h = makeDelayedHarness(snapshot: healthySnapshot())

        h.vm.recheckNow()
        await h.probe.waitUntilStarted()

        XCTAssertTrue(h.vm.isProbing)

        await h.probe.resumeFirst(with: geoOutcome())
        await h.vm.awaitPendingProbe()
        await settle()

        XCTAssertFalse(h.vm.isProbing)
        h.vm.stop()
    }

    func test_manual_recheck_lifts_the_block_as_soon_as_the_service_answers_again() async {
        let h = makeDelayedHarness(snapshot: healthySnapshot())
        h.vm.handle(.networkPath)
        await h.probe.waitUntilStarted()
        await h.probe.resumeFirst(with: .unavailable("таймаут запроса"))
        await h.vm.awaitPendingProbe()
        XCTAssertEqual(h.vm.state, .unsafe(.geoUnavailable("таймаут запроса")))

        h.vm.recheckNow()
        await h.probe.waitUntilStarted(atLeast: 2)
        await h.probe.resumeFirst(with: geoOutcome())
        await h.vm.awaitPendingProbe()

        XCTAssertEqual(
            h.vm.state, .safe(h.vm.lastReading),
            "восстановившийся сервис снимает блокировку сразу, а не через тик поллинга"
        )
        h.vm.stop()
    }

    func test_second_tap_while_probing_does_not_spend_another_request() async {
        let h = makeDelayedHarness(snapshot: healthySnapshot())

        h.vm.recheckNow()
        await h.probe.waitUntilStarted()
        h.vm.recheckNow()
        await settle()

        let starts = await h.probe.starts()
        XCTAssertEqual(starts, 1, "у подтверждающего сервиса лимит: спам кнопкой его не жжёт")
        h.vm.stop()
    }

    func test_probe_result_is_kept_for_the_popup_even_when_the_service_was_silent() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: .unavailable("таймаут запроса"))
        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()

        XCTAssertEqual(
            h.vm.lastReport?.ipinfo, .failed(.other("таймаут запроса")),
            "молчание сервиса обязано доезжать до экрана, а не только до журнала"
        )
    }

    private func makeCountingHarness(
        targets: [String],
        resolverMapping: [String: String]
    ) -> (vm: GuardVM, locator: CountingLocator, settings: SettingsStore) {
        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        settings.isEnabled = true
        settings.vpnServiceID = "HAPP"
        settings.targets = targets

        let locator = CountingLocator(
            bundlePaths: [targetBundleID: targetPath],
            processes: [
                .init(pid: 500, executablePath: "\(targetPath)/Contents/MacOS/Target"),
                .init(pid: 600, executablePath: "/usr/bin/pico"),
            ]
        )

        let vm = GuardVM(
            settings: settings,
            eventLog: EventLogStore(defaults: defaults),
            snapshotReader: StubSnapshotReader(snapshotValue: vpnDownSnapshot()),
            geoProbe: StubGeoProbe(geoOutcome()),
            locator: locator,
            resolver: StubResolver(mapping: resolverMapping),
            killer: SpyKiller(),
            notifier: SpyNotifier(),
            events: ManualEventSource(),
            debounceInterval: 0
        )

        return (vm, locator, settings)
    }

    func test_local_vpn_down_uses_one_process_scan() {

        let h = makeCountingHarness(
            targets: [targetBundleID],
            resolverMapping: [targetBundleID: targetPath]
        )

        h.vm.handle(.networkPath)

        XCTAssertEqual(
            h.locator.scanCount, 1,
            "решение, список для UI и завершение целей обслуживает один обход"
        )
    }

    func test_no_argv_collection_without_script_rules() {
        let h = makeCountingHarness(
            targets: [targetBundleID],
            resolverMapping: [targetBundleID: targetPath]
        )

        h.vm.handle(.networkPath)

        XCTAssertEqual(h.locator.argumentsRequested, [false])
    }

    func test_argv_is_collected_when_a_script_target_exists() {
        let h = makeCountingHarness(
            targets: ["qwen"],
            resolverMapping: ["qwen": "/opt/homebrew/lib/qwen/cli.js"]
        )

        h.vm.handle(.networkPath)

        XCTAssertEqual(h.locator.argumentsRequested, [true])
    }

    func test_local_kill_path_p95_stays_under_budget_on_250_processes() {

        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        settings.isEnabled = true
        settings.vpnServiceID = "HAPP"
        settings.targets = [targetBundleID]

        var processes: [ProcessSnapshot] = (1...248).map { index in
            .init(
                pid: Int32(1000 + index), parentPID: 1,
                executablePath: "/Applications/Other\(index).app/Contents/MacOS/Other\(index)"
            )
        }
        processes.append(.init(pid: 500, parentPID: 1, executablePath: "\(targetPath)/Contents/MacOS/Target"))
        processes.append(.init(pid: 501, parentPID: 500, executablePath: "/usr/bin/curl"))

        let vm = GuardVM(
            settings: settings,
            eventLog: EventLogStore(defaults: defaults),
            snapshotReader: StubSnapshotReader(snapshotValue: vpnDownSnapshot()),
            geoProbe: StubGeoProbe(geoOutcome()),
            locator: StubLocator(bundlePaths: [targetBundleID: targetPath], processes: processes),
            resolver: StubResolver(mapping: [targetBundleID: targetPath]),
            killer: SpyKiller(),
            notifier: SpyNotifier(),
            events: ManualEventSource(),
            debounceInterval: 0
        )

        var samples: [Double] = []
        for _ in 0..<20 {
            let started = ContinuousClock.now
            vm.handle(.networkPath)
            let elapsed = ContinuousClock.now - started
            samples.append(
                Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
            )
        }

        let sorted = samples.sorted()
        let p95 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        XCTAssertLessThan(
            p95, 0.05,
            "локальное решение, обход процессов и завершение целей: p95 = \(p95) с"
        )
    }

    func test_running_targets_list_parents_of_the_guarded_app() {
        let h = makeHarness(
            snapshot: healthySnapshot(),
            geo: geoOutcome(),
            processes: [
                .init(pid: 500, parentPID: 1, executablePath: "\(targetPath)/Contents/MacOS/Target"),
                .init(pid: 501, parentPID: 500, executablePath: "\(targetPath)/Contents/MacOS/Renderer"),
                .init(pid: 900, parentPID: 1, executablePath: "/Applications/Other.app/Contents/MacOS/Other"),
            ]
        )

        h.vm.refreshRunningTargets()

        XCTAssertEqual(h.vm.runningTargets.map(\.pid), [500], "чужое приложение в список не попадает")
        XCTAssertEqual(h.vm.runningTargets.first?.processCount, 2)
        XCTAssertEqual(h.vm.runningTargets.first?.kind, .appBundle)
    }

    func test_running_targets_are_empty_without_configured_targets() {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome())
        h.settings.targets = []

        h.vm.refreshRunningTargets()

        XCTAssertTrue(h.vm.runningTargets.isEmpty)
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
                .init(uuid: "WIFI", name: "Wi-Fi", activeInterface: "en0", isVPN: false),
                .init(uuid: "HAPP", name: "Happ", activeInterface: "utun6", isVPN: true),
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

    func test_healthy_network_ends_in_safe_state_after_verification() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome())

        h.vm.handle(.networkPath)
        XCTAssertEqual(
            h.vm.state, .unsafe(.verificationPending),
            "пока страна не подтверждена, состояние обязано быть небезопасным"
        )

        await h.vm.awaitPendingProbe()

        XCTAssertEqual(h.vm.state, .safe(h.vm.lastReading))
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
        XCTAssertEqual(h.killer.killedBatches, [[500, 501], [500, 501]])

        // Первая запись — завершение на время проверки, вторая — настоящая причина.
        XCTAssertEqual(h.log.events.count, 2)
        XCTAssertEqual(h.log.events.first?.country, "RU")
        XCTAssertEqual(
            h.log.events.first?.reasonText,
            UnsafeReason.blockedCountry(code: "RU", source: "ipinfo").displayText
        )
        XCTAssertEqual(h.log.events.last?.reasonText, UnsafeReason.verificationPending.displayText)
        XCTAssertEqual(h.notifier.messages.count, 2)
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
        settings.vpnServiceID = "HAPP"
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
                      arguments: ["node", "/opt/homebrew/lib/qwen/cli.js", "chat"]),
                .init(pid: 801, executablePath: "/opt/homebrew/bin/node",
                      arguments: ["node", "/Users/me/other-project/server.js"]),
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
        settings.vpnServiceID = "HAPP"
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
        settings.vpnServiceID = "HAPP"
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

    func test_only_qualified_vpns_are_offered_as_candidates() {

        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome())
        h.vm.refreshVPNCandidates()
        XCTAssertEqual(h.vm.availableVPNs.map(\.name), ["Happ"])
    }

    func test_running_process_count_counts_only_target_bundle() {

        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome())
        h.vm.refreshRunningTargets()

        XCTAssertEqual(h.vm.runningProcessCount(forTarget: targetBundleID), 2)
        XCTAssertEqual(h.vm.runningProcessCount(forTarget: "com.unknown"), 0)
    }

    func test_process_count_does_not_start_its_own_scan_per_target() {

        let h = makeCountingHarness(
            targets: [targetBundleID],
            resolverMapping: [targetBundleID: targetPath]
        )
        h.vm.refreshRunningTargets()
        let scansAfterRefresh = h.locator.scanCount

        for _ in 0..<5 { _ = h.vm.runningProcessCount(forTarget: targetBundleID) }

        XCTAssertEqual(h.locator.scanCount, scansAfterRefresh)
    }

    func test_stop_releases_the_event_source() {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome())
        h.vm.start()
        XCTAssertTrue(h.events.isListening)
        h.vm.stop()
        XCTAssertTrue(h.events.stopped)
    }
}
