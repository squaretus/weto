import XCTest
@testable import WetoShared
import WetoCore
import WetoSystem

/// Снимок сети, который тест умеет менять на ходу: сеть под охраной живая,
/// и половина случаев — как раз про её изменение.
private final class StubSnapshotReader: NetworkSnapshotReading, @unchecked Sendable {
    var snapshotValue: NetworkSnapshot

    init(snapshotValue: NetworkSnapshot) { self.snapshotValue = snapshotValue }

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
    case .degraded(let previous, let detail):
        // Ровно та форма, которую даёт резервный путь пробы: ipinfo молчит,
        // адрес назвал резервный сервис.
        return GeoProbeReport(
            ip: previous.ip,
            ipinfo: .failed(.other(detail)),
            confirmation: previous.confirmedCountry.map { .answered($0) } ?? .failed(.unreachable),
            confirmSource: .geojs,
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

    /// Выбранное VPN-приложение — такая же цель по форме: bundle ID и путь.
    private let vpnAppID = "su.ffg.happ"
    private let vpnAppPath = "/Applications/Happ.app"

    /// Процессы машины: цель, её потомок, чужое приложение и живой VPN-клиент.
    private var defaultProcesses: [ProcessSnapshot] {
        [
            .init(pid: 500, executablePath: "\(targetPath)/Contents/MacOS/Target"),
            .init(
                pid: 501,
                executablePath: "\(targetPath)/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"
            ),
            .init(pid: 900, executablePath: "/Applications/Other.app/Contents/MacOS/Other"),
            .init(pid: 700, executablePath: "\(vpnAppPath)/Contents/MacOS/Happ"),
        ]
    }

    /// Тот же набор, но VPN-клиент закрыт.
    private var processesWithoutVPNApp: [ProcessSnapshot] {
        defaultProcesses.filter { $0.pid != 700 }
    }

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
        NetworkSnapshot(outgoing: OutgoingRoute(interface: "utun6", address: "198.18.0.1"))
    }

    /// Трафик ушёл мимо туннеля — для отпечатка это другое состояние сети.
    private func directSnapshot() -> NetworkSnapshot {
        NetworkSnapshot(outgoing: OutgoingRoute(interface: "en0", address: "192.168.0.100"))
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
        let network: StubSnapshotReader
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
        settings.vpnAppRule = vpnAppID
        settings.blockedCountryCodes = ["RU"]
        settings.targets = [targetBundleID]
        settings.targets += executables

        let killer = SpyKiller()
        let probe = StubGeoProbe(geo)
        let notifier = SpyNotifier()
        let events = ManualEventSource()
        let log = EventLogStore(defaults: defaults)
        let network = StubSnapshotReader(snapshotValue: snapshot)

        let vm = GuardVM(
            settings: settings,
            eventLog: log,
            snapshotReader: network,
            geoProbe: probe,
            locator: StubLocator(
                bundlePaths: [targetBundleID: targetPath, vpnAppID: vpnAppPath],
                processes: processes ?? defaultProcesses
            ),
            resolver: StubResolver(mapping: [
                targetBundleID: targetPath,
                vpnAppID: vpnAppPath,
                "nano": "/usr/bin/pico",
                "qwen": "/opt/homebrew/lib/qwen/cli.js",
            ]),
            killer: killer,
            notifier: notifier,
            events: events,
            debounceInterval: 0.01
        )

        return Harness(vm: vm, killer: killer, probe: probe, notifier: notifier,
                       events: events, settings: settings, log: log, network: network)
    }

    private struct DelayedHarness {
        let vm: GuardVM
        let killer: SpyKiller
        let probe: DelayedGeoProbe
        let settings: SettingsStore
        let log: EventLogStore
        let network: StubSnapshotReader
    }

    private func makeDelayedHarness(snapshot: NetworkSnapshot) -> DelayedHarness {
        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        settings.isEnabled = true
        settings.vpnAppRule = vpnAppID
        settings.blockedCountryCodes = ["RU"]
        settings.targets = [targetBundleID]

        let killer = SpyKiller()
        let probe = DelayedGeoProbe()
        let log = EventLogStore(defaults: defaults)
        let network = StubSnapshotReader(snapshotValue: snapshot)

        let vm = GuardVM(
            settings: settings,
            eventLog: log,
            snapshotReader: network,
            geoProbe: probe,
            locator: StubLocator(
                bundlePaths: [targetBundleID: targetPath, vpnAppID: vpnAppPath],
                processes: defaultProcesses
            ),
            resolver: StubResolver(mapping: [targetBundleID: targetPath, vpnAppID: vpnAppPath]),
            killer: killer,
            notifier: SpyNotifier(),
            events: ManualEventSource(),
            debounceInterval: 0
        )

        return DelayedHarness(
            vm: vm, killer: killer, probe: probe, settings: settings, log: log, network: network
        )
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

    /// Whitelist входит в ревизию конфигурации: его правка обязана обесценить
    /// вердикт, полученный до неё, — иначе цели жили бы на устаревшем ответе.
    func test_old_config_probe_result_is_ignored_after_whitelist_change() async {
        let h = makeDelayedHarness(snapshot: healthySnapshot())

        h.vm.handle(.networkPath)
        await h.probe.waitUntilStarted()

        h.settings.allowedCountryCodes = ["DE"]
        await settle()

        await h.probe.resumeFirst(with: geoOutcome())
        await settle()

        XCTAssertEqual(h.vm.state, .unsafe(.verificationPending))
    }

    /// Ужесточение whitelist на работающей цели: страна выхода перестаёт быть
    /// разрешённой, и цель обязана быть завершена, а причина — попасть в журнал
    /// человеческим текстом.
    func test_tightening_the_whitelist_kills_a_running_target() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome())

        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()
        XCTAssertEqual(h.vm.state, .safe(h.vm.lastReading))

        h.settings.allowedCountryCodes = ["DE"]
        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()

        XCTAssertEqual(h.vm.state, .unsafe(.notWhitelistedCountry("KZ")))
        XCTAssertEqual(h.killer.killedBatches.last, [500, 501])
        XCTAssertEqual(
            h.log.events.first?.reasonText,
            UnsafeReason.notWhitelistedCountry("KZ").displayText
        )
    }

    func test_adding_a_target_while_unsafe_kills_without_waiting_for_tick() {
        let h = makeHarness(
            snapshot: healthySnapshot(),
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

    func test_choosing_a_vpn_app_that_is_not_running_kills_immediately() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome())
        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()
        XCTAssertEqual(h.vm.state, .safe(h.vm.lastReading))

        h.settings.vpnAppRule = "com.example.absent"

        XCTAssertEqual(h.vm.state, .unsafe(.vpnAppNotRunning))
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

    /// Штатный тик — локальная работа: процессы, статус, отпечаток. В сеть он не ходит,
    /// иначе частота опроса системы и частота обращений к чужим сервисам оказываются
    /// одним и тем же числом, и учащение первого жжёт лимиты второго.
    func test_routine_tick_does_not_spend_a_request_while_the_verdict_is_fresh() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome())
        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()
        let callsAfterVerdict = await h.probe.calls()

        h.vm.handle(.tick)
        await h.vm.awaitPendingProbe()

        let callsAfterTick = await h.probe.calls()
        XCTAssertEqual(callsAfterTick, callsAfterVerdict, "тик в сеть не ходит")
        XCTAssertEqual(h.vm.state, .safe(h.vm.lastReading))
    }

    /// А расписание гео — ходит: страна выхода может смениться и на неизменном пути.
    func test_geo_schedule_asks_the_services_again() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome())
        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()
        let callsAfterVerdict = await h.probe.calls()

        h.vm.handle(.geoSchedule)
        await h.vm.awaitPendingProbe()

        let callsAfterSchedule = await h.probe.calls()
        XCTAssertEqual(callsAfterSchedule, callsAfterVerdict + 1)
    }

    /// Таймаут ipinfo равен периоду расписания, поэтому пробы обязаны не накладываться.
    func test_geo_schedule_does_not_stack_requests_while_one_is_in_flight() async {
        let h = makeDelayedHarness(snapshot: healthySnapshot())

        h.vm.handle(.geoSchedule)
        await h.probe.waitUntilStarted()
        h.vm.handle(.geoSchedule)
        h.vm.handle(.geoSchedule)
        await settle()

        let starts = await h.probe.starts()
        XCTAssertEqual(starts, 1, "новая проба не стартует, пока прошлая в полёте")
        h.vm.stop()
    }

    /// Второй VPN, живущий рядом, — не событие для охраны.
    ///
    /// Корпоративный клиент рвёт связь и поднимается сам. Носитель трафика при этом
    /// не шелохнулся, значит и вердикт остался в силе: состава интерфейсов
    /// в отпечатке нет вовсе.
    func test_a_foreign_vpn_reconnecting_does_not_touch_the_targets() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome())
        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()
        let batchesAfterFirstVerdict = h.killer.killedBatches.count

        h.network.snapshotValue = NetworkSnapshot(
            outgoing: OutgoingRoute(interface: "utun6", address: "198.18.0.1")
        )
        h.vm.handle(.networkPath)

        XCTAssertEqual(
            h.vm.state, .safe(h.vm.lastReading),
            "чужой туннель не повод объявлять подключение непроверенным"
        )
        await h.vm.awaitPendingProbe()
        XCTAssertEqual(h.killer.killedBatches.count, batchesAfterFirstVerdict)
    }

    /// Обратная сторона: туннель переподключился и трафик уходит через другой
    /// интерфейс — вердикт обесценен, выход в сеть теперь другой.
    func test_the_tunnel_reconnecting_still_demands_a_new_verdict() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome())
        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()

        h.network.snapshotValue = NetworkSnapshot(
            outgoing: OutgoingRoute(interface: "utun9", address: "198.18.0.1")
        )
        h.vm.handle(.networkPath)

        XCTAssertEqual(h.vm.state, .unsafe(.verificationPending))
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

    // MARK: - Отказ ipinfo при доказанно том же адресе

    /// Молчание ipinfo — не повод завершать цели, если резервный сервис назвал наш адрес
    /// и он совпал с адресом прошлого вердикта. Тот же адрес — та же страна.
    /// Ровно из-за этого у пользователя умирал `claude` при полностью исправном VPN:
    /// квота подтверждающего сервиса делится с соседями по выходу VPN, и его 429
    /// приходил регулярно.
    func test_silent_ipinfo_with_the_same_address_keeps_the_targets() async {
        let h = makeDelayedHarness(snapshot: healthySnapshot())
        h.vm.handle(.networkPath)
        await h.probe.waitUntilStarted()
        await h.probe.resumeFirst(with: geoOutcome())
        await h.vm.awaitPendingProbe()
        XCTAssertEqual(h.vm.state, .safe(h.vm.lastReading))
        let batchesAfterVerdict = h.killer.killedBatches.count

        h.vm.recheckNow()
        await h.probe.waitUntilStarted(atLeast: 2)
        await h.probe.resumeFirst(with: .degraded(
            previous: GeoReading(
                ip: "203.0.113.28",
                primaryCountry: "KZ",
                confirmedCountry: "KZ",
                confirmSource: .freeipapi
            ),
            detail: "HTTP 429"
        ))
        await h.vm.awaitPendingProbe()

        XCTAssertEqual(h.vm.state, .safe(h.vm.lastReading), "адрес тот же — перепроверять нечего")
        XCTAssertEqual(h.killer.killedBatches.count, batchesAfterVerdict)
        h.vm.stop()
    }

    /// Адрес сменился, а страны для него никто не назвал — вердикта нет, и снисхождения тоже.
    func test_silent_ipinfo_with_a_new_address_kills() async {
        let h = makeDelayedHarness(snapshot: healthySnapshot())
        h.vm.handle(.networkPath)
        await h.probe.waitUntilStarted()
        await h.probe.resumeFirst(with: geoOutcome())
        await h.vm.awaitPendingProbe()

        h.vm.recheckNow()
        await h.probe.waitUntilStarted(atLeast: 2)
        await h.probe.resumeFirst(with: .degraded(
            previous: GeoReading(
                ip: "198.51.100.231",
                primaryCountry: "KZ",
                confirmedCountry: "KZ",
                confirmSource: .freeipapi
            ),
            detail: "HTTP 429"
        ))
        await h.vm.awaitPendingProbe()

        XCTAssertEqual(
            h.vm.state,
            .unsafe(.geoUnavailable("адрес сменился, страна не проверена")),
            "новый адрес не наследует страну прошлого"
        )
        h.vm.stop()
    }

    /// Молчат оба сервиса — адреса нет вовсе, доказывать нечем.
    func test_silence_from_both_services_kills() async {
        let h = makeDelayedHarness(snapshot: healthySnapshot())
        h.vm.handle(.networkPath)
        await h.probe.waitUntilStarted()
        await h.probe.resumeFirst(with: geoOutcome())
        await h.vm.awaitPendingProbe()

        h.vm.recheckNow()
        await h.probe.waitUntilStarted(atLeast: 2)
        await h.probe.resumeFirst(with: .unavailable("таймаут запроса"))
        await h.vm.awaitPendingProbe()

        XCTAssertEqual(h.vm.state, .unsafe(.geoUnavailable("таймаут запроса")))
        h.vm.stop()
    }

    /// Цели живут, но защита держится на том, что адрес не менялся, а не на свежем
    /// ответе ipinfo. Глаз обязан это видеть: зелёный тут врал бы.
    func test_grace_shows_yellow_while_ipinfo_stays_silent() async {
        let h = makeDelayedHarness(snapshot: healthySnapshot())
        h.vm.handle(.networkPath)
        await h.probe.waitUntilStarted()
        await h.probe.resumeFirst(with: geoOutcome())
        await h.vm.awaitPendingProbe()
        XCTAssertEqual(h.vm.statusColor, .green)

        h.vm.recheckNow()
        await h.probe.waitUntilStarted(atLeast: 2)
        await h.probe.resumeFirst(with: .degraded(
            previous: GeoReading(
                ip: "203.0.113.28",
                primaryCountry: "KZ",
                confirmedCountry: "KZ",
                confirmSource: .freeipapi
            ),
            detail: "HTTP 429"
        ))
        await h.vm.awaitPendingProbe()

        XCTAssertEqual(h.vm.state, .safe(h.vm.lastReading))
        XCTAssertEqual(h.vm.statusColor, .yellow)
        h.vm.stop()
    }

    /// Сменился путь в сеть — снисхождение отменяется, даже когда адрес совпал:
    /// вердикт при смене пути недействителен по построению.
    func test_route_change_cancels_the_grace_even_on_the_same_address() async {
        let h = makeDelayedHarness(snapshot: healthySnapshot())
        h.vm.handle(.networkPath)
        await h.probe.waitUntilStarted()
        await h.probe.resumeFirst(with: geoOutcome())
        await h.vm.awaitPendingProbe()
        XCTAssertEqual(h.vm.state, .safe(h.vm.lastReading))

        h.network.snapshotValue = NetworkSnapshot(
            outgoing: OutgoingRoute(interface: "utun9", address: "198.18.0.1")
        )
        h.vm.handle(.networkPath)

        await h.probe.waitUntilStarted(atLeast: 2)
        await h.probe.resumeFirst(with: .degraded(
            previous: GeoReading(
                ip: "203.0.113.28",
                primaryCountry: "KZ",
                confirmedCountry: "KZ",
                confirmSource: .freeipapi
            ),
            detail: "HTTP 429"
        ))
        await h.vm.awaitPendingProbe()

        XCTAssertEqual(h.vm.state, .unsafe(.geoUnavailable("HTTP 429")))
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

    /// Fail-closed срабатывает раньше вердикта, поэтому в журнал первым попадает
    /// «подключение ещё не проверено» — ответ «пока не знаю». Через миг причина
    /// известна, и запись эпизода обязана назвать её: иначе журнал навсегда
    /// сохраняет отговорку вместо того, из-за чего цели и умерли.
    func test_journal_entry_of_an_episode_gets_the_settled_reason() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome(primary: "RU"))

        h.vm.handle(.networkPath)

        XCTAssertEqual(h.vm.state, .unsafe(.verificationPending))
        XCTAssertEqual(h.log.events.count, 1)
        XCTAssertEqual(h.log.events[0].reasonText, "Подключение ещё не проверено")

        await h.vm.awaitPendingProbe()

        XCTAssertEqual(h.vm.state, .unsafe(.blockedCountry(code: "RU", source: "ipinfo")))
        XCTAssertEqual(h.log.events.count, 1, "эпизод остаётся одной записью, а не двумя")
        XCTAssertEqual(h.log.events[0].reasonText, "Обнаружена страна RU по данным ipinfo")
        XCTAssertEqual(h.log.events[0].country, "RU", "показания вердикта тоже дописываются")
        XCTAssertEqual(h.log.events[0].ip, "203.0.113.28")
    }

    /// Уточнение — про один эпизод. Новое падение после возврата к жизни обязано
    /// заводить свою запись, а не переписывать прошлую.
    func test_a_new_episode_does_not_rewrite_the_previous_entry() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome())

        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()
        XCTAssertEqual(h.vm.state, .safe(h.vm.lastReading))
        XCTAssertEqual(h.log.events.count, 1)
        let first = h.log.events[0]

        h.network.snapshotValue = directSnapshot()
        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()

        XCTAssertEqual(h.log.events.count, 2, "второй эпизод — вторая запись")
        XCTAssertEqual(h.log.events.last?.id, first.id)
        XCTAssertEqual(h.log.events.last?.reasonText, first.reasonText)
    }

    private func makeCountingHarness(
        targets: [String],
        resolverMapping: [String: String]
    ) -> (vm: GuardVM, locator: CountingLocator, settings: SettingsStore) {
        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        settings.isEnabled = true
        settings.vpnAppRule = vpnAppID
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
            snapshotReader: StubSnapshotReader(snapshotValue: healthySnapshot()),
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
        settings.vpnAppRule = vpnAppID
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
            snapshotReader: StubSnapshotReader(snapshotValue: healthySnapshot()),
            geoProbe: StubGeoProbe(geoOutcome()),
            locator: StubLocator(bundlePaths: [targetBundleID: targetPath], processes: processes),
            resolver: StubResolver(mapping: [targetBundleID: targetPath, vpnAppID: vpnAppPath]),
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
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome(),
                            processes: processesWithoutVPNApp)

        h.vm.handle(.networkPath)

        XCTAssertEqual(h.vm.state, .unsafe(.vpnAppNotRunning))
        XCTAssertEqual(h.killer.killedBatches, [[500, 501]], "убиты только процессы цели")
        let probeCalls = await h.probe.calls()
        XCTAssertEqual(probeCalls, 0, "сетевая проба не должна была запускаться")
    }

    /// Трафик ушёл мимо туннеля — для охраны это смена состояния сети:
    /// прежний вердикт недействителен, и цели завершаются до ответа сети.
    func test_traffic_moving_off_the_tunnel_invalidates_the_verdict() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome())
        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()
        XCTAssertEqual(h.vm.state, .safe(h.vm.lastReading))

        h.network.snapshotValue = directSnapshot()
        h.vm.handle(.networkPath)

        XCTAssertEqual(h.vm.state, .unsafe(.verificationPending))
    }

    /// Закрыли VPN-клиент — цели завершаются в ту же секунду, не дожидаясь тика:
    /// событие о завершении приложения приходит сразу.
    func test_closing_the_vpn_app_kills_at_once() async {
        let locator = MutableLocator(
            bundlePaths: [targetBundleID: targetPath, vpnAppID: vpnAppPath],
            processes: defaultProcesses
        )
        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        settings.isEnabled = true
        settings.vpnAppRule = vpnAppID
        settings.targets = [targetBundleID]

        let killer = SpyKiller()
        let vm = GuardVM(
            settings: settings,
            eventLog: EventLogStore(defaults: defaults),
            snapshotReader: StubSnapshotReader(snapshotValue: healthySnapshot()),
            geoProbe: StubGeoProbe(geoOutcome()),
            locator: locator,
            resolver: StubResolver(mapping: [targetBundleID: targetPath, vpnAppID: vpnAppPath]),
            killer: killer,
            notifier: SpyNotifier(),
            events: ManualEventSource(),
            debounceInterval: 0.01
        )

        vm.handle(.networkPath)
        await vm.awaitPendingProbe()
        XCTAssertEqual(vm.state, .safe(vm.lastReading))

        locator.processes = processesWithoutVPNApp
        vm.handle(.appTerminated(bundleID: vpnAppID))

        XCTAssertEqual(vm.state, .unsafe(.vpnAppNotRunning))
        XCTAssertEqual(killer.killedBatches.last, [500, 501], "убиты цели, но не сам клиент")
    }

    /// Выбранное VPN-приложение не завершается никогда: охрана, убившая свой
    /// источник защиты, оставила бы состояние необратимым.
    func test_the_vpn_app_is_never_killed() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome(primary: "RU"))

        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()

        XCTAssertEqual(h.vm.state, .unsafe(.blockedCountry(code: "RU", source: "ipinfo")))
        XCTAssertFalse(h.killer.killedBatches.isEmpty, "цели обязаны быть завершены")
        XCTAssertFalse(
            h.killer.killedBatches.flatMap { $0 }.contains(700),
            "процесс VPN-клиента не должен попадать под нож"
        )
    }

    /// Цель, добавленную на ходу, охрана обязана подхватить без перезапуска
    /// приложения: пользователь добавляет её именно потому, что она уже запущена.
    func test_a_target_added_while_running_is_guarded_without_a_restart() async {
        let locator = MutableLocator(
            bundlePaths: [targetBundleID: targetPath, vpnAppID: vpnAppPath],
            processes: defaultProcesses + [.init(pid: 601, executablePath: "/usr/bin/pico")]
        )
        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        settings.isEnabled = true
        settings.vpnAppRule = vpnAppID
        settings.targets = [targetBundleID]

        let killer = SpyKiller()
        let probe = StubGeoProbe(geoOutcome())
        let vm = GuardVM(
            settings: settings,
            eventLog: EventLogStore(defaults: defaults),
            snapshotReader: StubSnapshotReader(snapshotValue: healthySnapshot()),
            geoProbe: probe,
            locator: locator,
            resolver: StubResolver(mapping: [
                targetBundleID: targetPath,
                vpnAppID: vpnAppPath,
                "nano": "/usr/bin/pico",
            ]),
            killer: killer,
            notifier: SpyNotifier(),
            events: ManualEventSource(),
            debounceInterval: 0.01
        )

        vm.handle(.networkPath)
        await vm.awaitPendingProbe()
        XCTAssertEqual(vm.state, .safe(vm.lastReading))
        XCTAssertFalse(
            vm.runningTargets.contains { $0.entry == "nano" },
            "цели ещё нет в списке — проверяем именно её появление"
        )

        settings.targets += ["nano"]

        XCTAssertTrue(
            vm.runningTargets.contains { $0.entry == "nano" },
            "добавленная цель обязана появиться в живых сразу, не дожидаясь тика"
        )
        await vm.awaitPendingProbe()
    }

    /// И под красным статусом добавленная цель завершается сразу, не дожидаясь
    /// ни тика, ни повторного запуска приложения.
    func test_a_target_added_while_unsafe_is_killed_at_once() async {
        let locator = MutableLocator(
            bundlePaths: [targetBundleID: targetPath, vpnAppID: vpnAppPath],
            processes: processesWithoutVPNApp + [.init(pid: 601, executablePath: "/usr/bin/pico")]
        )
        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        settings.isEnabled = true
        settings.vpnAppRule = vpnAppID
        settings.targets = [targetBundleID]

        let killer = SpyKiller()
        let vm = GuardVM(
            settings: settings,
            eventLog: EventLogStore(defaults: defaults),
            snapshotReader: StubSnapshotReader(snapshotValue: healthySnapshot()),
            geoProbe: StubGeoProbe(geoOutcome()),
            locator: locator,
            resolver: StubResolver(mapping: [
                targetBundleID: targetPath,
                vpnAppID: vpnAppPath,
                "nano": "/usr/bin/pico",
            ]),
            killer: killer,
            notifier: SpyNotifier(),
            events: ManualEventSource(),
            debounceInterval: 0.01
        )

        vm.handle(.networkPath)
        XCTAssertEqual(vm.state, .unsafe(.vpnAppNotRunning))

        settings.targets += ["nano"]

        XCTAssertTrue(
            killer.killedBatches.flatMap { $0 }.contains(601),
            "цель, добавленная под красным статусом, обязана быть завершена сразу"
        )
    }

    /// То же самое, но без подмен на границе: настоящее разрешение цели
    /// (`TargetResolver`) и настоящий обход процессов (`ProcessRegistry`).
    /// Подменён только убийца — завершать чужие процессы тест не имеет права.
    func test_a_live_process_added_as_a_target_is_seen_without_a_restart() async throws {
        let victim = Process()
        victim.executableURL = URL(fileURLWithPath: "/bin/sleep")
        victim.arguments = ["30"]
        try victim.run()
        defer { victim.terminate() }

        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        settings.isEnabled = true
        settings.vpnAppRule = vpnAppID
        settings.targets = []

        let vm = GuardVM(
            settings: settings,
            eventLog: EventLogStore(defaults: defaults),
            snapshotReader: StubSnapshotReader(snapshotValue: healthySnapshot()),
            geoProbe: StubGeoProbe(geoOutcome()),
            locator: ProcessRegistry(),
            resolver: TargetResolver(),
            killer: SpyKiller(),
            notifier: SpyNotifier(),
            events: ManualEventSource(),
            debounceInterval: 0.01
        )

        vm.handle(.tick)
        XCTAssertTrue(vm.runningTargets.isEmpty, "целей ещё нет")

        settings.targets = ["/bin/sleep"]
        vm.handle(.tick)

        XCTAssertTrue(
            vm.runningTargets.contains { $0.entry == "/bin/sleep" },
            "живой процесс, добавленный целью, обязан найтись без перезапуска: \(vm.runningTargets)"
        )
    }

    func test_disabled_guard_never_kills() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome(), enabled: false,
                            processes: processesWithoutVPNApp)

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

        // Одно падение — одна запись: причина в ней уточняется с «ещё не проверено»
        // на настоящую, как только вердикт готов. Двумя записями это выглядело как
        // два разных события, а на живой машине второй записи не было вовсе —
        // цели к тому моменту уже мертвы, завершать нечего.
        XCTAssertEqual(h.log.events.count, 1)
        XCTAssertEqual(h.log.events.first?.country, "RU")
        XCTAssertEqual(
            h.log.events.first?.reasonText,
            UnsafeReason.blockedCountry(code: "RU", source: "ipinfo").displayText
        )
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
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome(),
                            processes: processesWithoutVPNApp)
        h.vm.handle(.networkPath)
        XCTAssertEqual(h.killer.killedBatches.count, 1)

        h.vm.handle(.appLaunched(bundleID: targetBundleID))

        XCTAssertEqual(h.killer.killedBatches.count, 2, "перезапущенная цель должна быть добита")
        XCTAssertEqual(h.log.events.count, 1, "те же pid повторно в журнал не пишутся")
    }

    func test_newly_launched_target_is_recorded_even_while_already_unsafe() async {

        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        settings.isEnabled = true
        settings.vpnAppRule = vpnAppID
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
            snapshotReader: StubSnapshotReader(snapshotValue: healthySnapshot()),
            geoProbe: StubGeoProbe(geoOutcome()),
            locator: locator,
            resolver: StubResolver(mapping: [targetBundleID: targetPath, vpnAppID: vpnAppPath]),
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
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome(),
                            processes: processesWithoutVPNApp)
        h.vm.handle(.networkPath)

        h.vm.handle(.appLaunched(bundleID: "com.apple.TextEdit"))

        XCTAssertEqual(h.killer.killedBatches.count, 1)
    }

    func test_eperm_is_surfaced_instead_of_being_swallowed() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome(),
                            processes: processesWithoutVPNApp)
        h.killer.setError(EPERM, forPID: 500)

        h.vm.handle(.networkPath)

        XCTAssertNotNil(h.vm.permissionFailure)
        XCTAssertTrue(h.vm.permissionFailure?.contains("500") == true)
    }

    func test_no_targets_running_does_not_produce_an_event() async {
        let h = makeHarness(
            snapshot: healthySnapshot(),
            geo: geoOutcome(),
            processes: [.init(pid: 900, executablePath: "/Applications/Other.app/Contents/MacOS/Other")]
        )

        h.vm.handle(.networkPath)

        XCTAssertTrue(h.killer.killedBatches.isEmpty)
        XCTAssertTrue(h.log.events.isEmpty)
        XCTAssertEqual(h.vm.state, .unsafe(.vpnAppNotRunning), "состояние всё равно небезопасное")
    }

    func test_symlinked_command_is_matched_by_resolved_path() async {

        let h = makeHarness(
            snapshot: healthySnapshot(),
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
            snapshot: healthySnapshot(),
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
            snapshot: healthySnapshot(),
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
        settings.vpnAppRule = vpnAppID
        settings.targets = []
        settings.targets = ["nano"]

        XCTAssertTrue(settings.guardConfig.hasTargets)
        XCTAssertEqual(
            GuardPolicy.decideLocal(isEnabled: true, vpn: .notRunning, config: settings.guardConfig),
            .kill(.vpnAppNotRunning)
        )
    }

    func test_first_episode_event_is_termination_second_is_launch_block() async {
        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        settings.isEnabled = true
        settings.vpnAppRule = vpnAppID
        settings.targets = [targetBundleID]

        let log = EventLogStore(defaults: defaults)
        let locator = MutableLocator(
            bundlePaths: [targetBundleID: targetPath],
            processes: [.init(pid: 500, executablePath: "\(targetPath)/Contents/MacOS/Target")]
        )
        let vm = GuardVM(
            settings: settings,
            eventLog: log,
            snapshotReader: StubSnapshotReader(snapshotValue: healthySnapshot()),
            geoProbe: StubGeoProbe(geoOutcome()),
            locator: locator,
            resolver: StubResolver(mapping: [targetBundleID: targetPath, vpnAppID: vpnAppPath]),
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

    // MARK: - Проверка по кнопке

    /// Кнопка отвечает на вопрос «где я сейчас», а не «нужна ли охране проверка».
    /// Выключенный VPN — основание завершить цели, но не повод молчать о стране.
    func test_manual_recheck_asks_geo_even_when_vpn_is_down() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome(primary: "KZ"),
                            processes: processesWithoutVPNApp)
        h.vm.start()
        await h.vm.awaitPendingProbe()

        // Число запросов не закрепляем: при выключенном VPN показания обновляются
        // и сами. Важно, что нажатие добавляет свой.
        let before = await h.probe.calls()

        h.vm.recheckNow()
        await h.vm.awaitPendingProbe()

        let calls = await h.probe.calls()
        XCTAssertEqual(calls, before + 1, "кнопка обязана сходить в сеть и при выключенном VPN")
        XCTAssertEqual(h.vm.lastReport?.ipinfo, .answered("KZ"))
        XCTAssertEqual(h.vm.state, .unsafe(.vpnAppNotRunning), "вердикт охраны кнопка не смягчает")
    }

    /// Показания обязаны обновляться и тогда, когда судьба целей решена локально.
    ///
    /// Экономия запросов относится к вердикту, а не к экрану: пока её
    /// распространяли и на показания, после падения VPN там навсегда оставались
    /// адрес и страна туннеля — то есть экран показывал защиту, которой уже нет.
    func test_the_readout_refreshes_while_the_vpn_is_down() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome(primary: "KZ"),
                            processes: processesWithoutVPNApp)

        h.vm.start()
        await h.vm.awaitPendingProbe()

        XCTAssertEqual(
            h.vm.lastReport?.ipinfo,
            .answered("KZ"),
            "экран обязан сказать, где пользователь сейчас, а не где был под VPN"
        )
        XCTAssertEqual(h.vm.state, .unsafe(.vpnAppNotRunning), "показания вердикт не смягчают")
    }

    /// Свежая установка: охрана выключена, целей нет — но узнать своё положение
    /// пользователь всё равно должен.
    func test_manual_recheck_asks_geo_when_guard_is_disabled() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome(), enabled: false)
        h.vm.start()
        await h.vm.awaitPendingProbe()

        h.vm.recheckNow()
        await h.vm.awaitPendingProbe()

        let calls = await h.probe.calls()
        XCTAssertEqual(calls, 1, "выключенная охрана не отменяет вопрос «где я сейчас»")
        XCTAssertNotNil(h.vm.lastReport)
        XCTAssertEqual(h.vm.state, .disabled, "состояние охраны от кнопки не меняется")
    }
}
