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
/// Трассы у заглушки настоящие по форме: журнал берёт их из отчёта, и без них
/// проверялась бы половина пути.
private func stubTraces(ip: String?, country: String?) -> [GeoServiceTrace] {
    [
        GeoServiceTrace(
            service: "ipinfo",
            url: "https://api.ipinfo.io/lite/me",
            httpStatus: 200,
            durationMilliseconds: 42,
            body: #"{"ip":"\#(ip ?? "")","country_code":"\#(country ?? "")"}"#
        )
    ]
}

private func stubReport(_ outcome: GeoOutcome) -> GeoProbeReport {
    switch outcome {
    case .resolved(let reading):
        return GeoProbeReport(
            ip: reading.ip,
            ipinfo: .answered(reading.primaryCountry),
            confirmation: reading.confirmedCountry.map { .answered($0) } ?? .failed(.unreachable),
            confirmSource: reading.confirmSource,
            hasNetworkPath: true,
            checkedAt: Date(),
            traces: stubTraces(ip: reading.ip, country: reading.primaryCountry)
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
    case .addressChanged:
        // Не форма ответа пробы: `addressChanged` синтезирует сам `GuardController`
        // из молчания ipinfo и ответа резервного сервиса. Стаб его не производит.
        fatalError("addressChanged не бывает сырым ответом пробы")
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

/// Резолвер, которому можно переставить путь цели: так выглядит обновление
/// инструмента, у которого в пути стоит номер версии.
private final class StubResolver: TargetResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String]

    init(mapping: [String: String]) { self.storage = mapping }

    var mapping: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func point(_ entry: String, to path: String) {
        lock.lock(); storage[entry] = path; lock.unlock()
    }

    func resolve(_ entry: String) -> TargetRule? {
        guard let path = mapping[entry] else { return nil }
        let kind: TargetKind = path.hasSuffix(".app")
            ? .appBundle
            : (path.hasSuffix(".js") ? .script : .binary)
        return TargetRule(entry: entry, displayName: entry, kind: kind, path: path)
    }
}

private final class SpySignaler: ProcessSignaling, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(signal: ProcessSignal, pids: [Int32])] = []
    private var errors: [Int32: Int32] = [:]

    /// Все партии сигналов по порядку: пауза, продолжение и завершение — разные
    /// новости, и тест обязан их различать.
    var batches: [(signal: ProcessSignal, pids: [Int32])] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    /// Пакеты, отправленные `.kill`: их смотрят тесты, где судьба целей решена
    /// доказательством, а не паузой.
    var killedBatches: [[Int32]] {
        lock.lock(); defer { lock.unlock() }
        return stored.filter { $0.signal == .kill }.map(\.pids)
    }

    func setError(_ code: Int32, forPID pid: Int32) {
        lock.lock(); errors[pid] = code; lock.unlock()
    }

    func send(_ signal: ProcessSignal, to pids: [Int32]) -> [SignalResult] {
        lock.lock()
        stored.append((signal: signal, pids: pids))
        let snapshot = errors
        lock.unlock()
        return pids.map { SignalResult(pid: $0, errorCode: snapshot[$0]) }
    }
}

private final class SpyNotifier: GuardNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private var kills: [String] = []
    private var backgroundedTargets: [String] = []

    var terminated: [String] {
        lock.lock(); defer { lock.unlock() }
        return kills
    }

    /// Цели, ушедшие в фон под паузой: им нужен `fg`, и об этом обязано прийти
    /// уведомление — иначе процесс просто «пропал».
    var backgrounded: [String] {
        lock.lock(); defer { lock.unlock() }
        return backgroundedTargets
    }

    func notifyTerminated(reasonText: String, killedCount: Int) {
        lock.lock(); kills.append(reasonText); lock.unlock()
    }

    func notifyBackgrounded(targetName: String) {
        lock.lock(); backgroundedTargets.append(targetName); lock.unlock()
    }
}

/// Учёт, чей файл не прочитался: единственный способ проверить, что признак порчи
/// не тонет молча, — граница хранилища.
private final class CorruptedStoppedLedger: StoppedLedgerPersisting, @unchecked Sendable {
    func load() -> StoppedLedgerReadout { .corrupted }
    func save(_ entries: [StoppedProcess]) {}
}

/// Кого попросили показать терминал: граница активации чужого окна.
private final class SpyTerminalLocator: TerminalLocating, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int32] = []

    var asked: [Int32] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func activateTerminal(owning pid: Int32, in processes: [ProcessSnapshot]) -> Bool {
        lock.lock(); stored.append(pid); lock.unlock()
        return true
    }
}

/// Часы под управлением теста: потолок паузы считается по времени, а не по числу тактов.
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
        let signaler: SpySignaler
        let probe: StubGeoProbe
        let notifier: SpyNotifier
        let events: ManualEventSource
        let settings: SettingsStore
        let log: EventLogStore
        let network: StubSnapshotReader
        let resolver: StubResolver
    }

    private func makeHarness(
        snapshot: NetworkSnapshot,
        geo: GeoOutcome,
        enabled: Bool = true,
        processes: [ProcessSnapshot]? = nil,
        executables: [String] = [],
        now: @escaping () -> Date = Date.init
    ) -> Harness {
        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        settings.isEnabled = enabled
        settings.vpnAppRule = vpnAppID
        settings.blockedCountryCodes = ["RU"]
        settings.targets = [targetBundleID]
        settings.targets += executables

        let signaler = SpySignaler()
        let probe = StubGeoProbe(geo)
        let notifier = SpyNotifier()
        let events = ManualEventSource()
        let log = EventLogStore(storage: InMemoryEventLog())
        let network = StubSnapshotReader(snapshotValue: snapshot)
        let resolver = StubResolver(mapping: [
            targetBundleID: targetPath,
            vpnAppID: vpnAppPath,
            "nano": "/usr/bin/pico",
            "qwen": "/opt/homebrew/lib/qwen/cli.js",
        ])

        let vm = GuardVM(
            settings: settings,
            eventLog: log,
            snapshotReader: network,
            geoProbe: probe,
            locator: StubLocator(
                bundlePaths: [targetBundleID: targetPath, vpnAppID: vpnAppPath],
                processes: processes ?? defaultProcesses
            ),
            resolver: resolver,
            signaler: signaler,
            ledger: StoppedLedger(storage: InMemoryStoppedLedger()),
            notifier: notifier,
            events: events,
            debounceInterval: 0.01,
            now: now
        )

        return Harness(vm: vm, signaler: signaler, probe: probe, notifier: notifier,
                       events: events, settings: settings, log: log, network: network,
                       resolver: resolver)
    }

    private struct DelayedHarness {
        let vm: GuardVM
        let signaler: SpySignaler
        let probe: DelayedGeoProbe
        let notifier: SpyNotifier
        let settings: SettingsStore
        let log: EventLogStore
        let network: StubSnapshotReader
    }

    private func makeDelayedHarness(
        snapshot: NetworkSnapshot,
        checkLog: CheckLogStore = CheckLogStore(storage: InMemoryCheckLog()),
        now: @escaping () -> Date = Date.init,
        processes: [ProcessSnapshot]? = nil,
        executables: [String] = [],
        ledger: StoppedLedger? = nil
    ) -> DelayedHarness {
        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        settings.isEnabled = true
        settings.vpnAppRule = vpnAppID
        settings.blockedCountryCodes = ["RU"]
        settings.targets = [targetBundleID]
        settings.targets += executables

        let signaler = SpySignaler()
        let probe = DelayedGeoProbe()
        let notifier = SpyNotifier()
        let log = EventLogStore(storage: InMemoryEventLog())
        let network = StubSnapshotReader(snapshotValue: snapshot)

        let vm = GuardVM(
            settings: settings,
            eventLog: log,
            checkLog: checkLog,
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
            ]),
            signaler: signaler,
            ledger: ledger ?? StoppedLedger(storage: InMemoryStoppedLedger()),
            notifier: notifier,
            events: ManualEventSource(),
            debounceInterval: 0,
            now: now
        )

        return DelayedHarness(
            vm: vm, signaler: signaler, probe: probe, notifier: notifier,
            settings: settings, log: log, network: network
        )
    }

    /// Выход через `utun5` — тот, на котором сняты оба эпизода из журнала владельца.
    private func utun5Snapshot() -> NetworkSnapshot {
        NetworkSnapshot(outgoing: OutgoingRoute(interface: "utun5", address: "198.18.0.1"))
    }

    /// Даёт отменённым задачам добежать до своих проверок, не привязываясь ко времени.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    /// Доводит молчание сервисов до исчерпания терпимости.
    ///
    /// `Constants.silenceToleranceProbes` неудачных проб при установленном вердикте
    /// и неизменном отпечатке ничего не меняют — это «Помехи», цели работают. Пауза
    /// приходит со следующей. Расписанием, а не кнопкой: кнопка занята индикатором
    /// `isProbing`, который гаснет своей задачей, и второе нажатие подряд может не уйти.
    ///
    /// `startedProbes` — сколько проб уже стартовало до вызова: `DelayedGeoProbe`
    /// считает старты с начала теста.
    @discardableResult
    private func spendSilenceTolerance(
        _ h: DelayedHarness,
        after startedProbes: Int,
        answering outcome: GeoOutcome = .unavailable("таймаут запроса")
    ) async -> Int {
        for attempt in 1...(Constants.silenceToleranceProbes + 1) {
            h.vm.handle(.geoSchedule)
            await h.probe.waitUntilStarted(atLeast: startedProbes + attempt)
            await h.probe.resumeFirst(with: outcome)
            await h.vm.awaitPendingProbe()
        }
        return startedProbes + Constants.silenceToleranceProbes + 1
    }

    /// Такт охраны не имеет права отменять пробу, которая ещё в полёте.
    ///
    /// Пока вердикт несвеж, каждый такт заново объявляет fail-closed и запускает
    /// пробу, снимая предыдущую. Такт идёт раз в секунду, а запрос к ipinfo с его
    /// таймаутом в пять — на медленном канале проба не успевает ответить никогда,
    /// и вердикт не приходит вовсе: ни сам по себе, ни по кнопке. Снаружи это
    /// выглядит как «нажал пять раз, запрос так и не ушёл».
    func test_a_tick_does_not_cancel_the_probe_in_flight() async {
        let h = makeDelayedHarness(snapshot: healthySnapshot())

        h.vm.handle(.networkPath)
        await h.probe.waitUntilStarted()
        XCTAssertEqual(h.vm.phase.title, "Проверка")

        // Секунда прошла, охрана сделала штатный такт — проба всё ещё в полёте.
        h.vm.handle(.tick)
        await settle()

        await h.probe.resumeFirst(with: geoOutcome(primary: "KZ", confirmed: "KZ"))
        await settle()

        let starts = await h.probe.starts()
        XCTAssertEqual(
            starts, 1,
            "такт запустил вторую пробу поверх летящей: первая отменена, запрос выброшен"
        )
        XCTAssertEqual(h.vm.phase.title, "Защищено", "ответ пробы обязан примениться")
    }

    /// То же про кнопку: пользователь нажал, запрос ушёл, и следующий такт
    /// не должен его снимать.
    func test_a_tick_does_not_cancel_the_probe_requested_by_the_button() async {
        let h = makeDelayedHarness(snapshot: healthySnapshot())

        h.vm.recheckNow()
        await h.probe.waitUntilStarted()

        h.vm.handle(.tick)
        await settle()

        await h.probe.resumeFirst(with: geoOutcome(primary: "KZ", confirmed: "KZ"))
        await settle()

        XCTAssertEqual(h.vm.phase.title, "Защищено", "проверка по кнопке обязана доехать")
    }

    /// Ответ пробы про прежний путь нельзя применять к новому.
    ///
    /// Раньше от этого спасала отмена: смена пути шла тиком, тик снимал летящую
    /// пробу. Отмену убрали — значит несовпадение отпечатка обязано отсекать
    /// ответ явно, иначе цели открываются на чужих показаниях.
    func test_an_answer_about_the_previous_path_is_not_applied_to_the_new_one() async {
        let h = makeDelayedHarness(snapshot: healthySnapshot())

        h.vm.handle(.networkPath)
        await h.probe.waitUntilStarted()

        // Пока проба летела, трафик поехал мимо туннеля.
        h.network.snapshotValue = directSnapshot()
        await h.probe.resumeFirst(with: geoOutcome(primary: "KZ", confirmed: "KZ"))
        await settle()

        XCTAssertEqual(
            h.vm.phase.title, "Проверка",
            "безопасный ответ про прежний выход не открывает цели на новом"
        )
    }

    /// Холодный старт ставит цели на паузу, а не завершает: вердикта нет — значит
    /// доказательства утечки нет тоже, а SIGKILL необратим.
    func test_start_pauses_targets_while_initial_probe_is_suspended() async {
        let h = makeDelayedHarness(snapshot: healthySnapshot())

        h.vm.start()
        await h.probe.waitUntilStarted()

        XCTAssertEqual(h.vm.phase.title, "Проверка")
        XCTAssertEqual(h.signaler.batches.first?.signal, .stop)
        XCTAssertEqual(h.signaler.batches.first?.pids, [500, 501])
        XCTAssertTrue(h.signaler.killedBatches.isEmpty, "ни одного SIGKILL без доказательства")
        h.vm.stop()
    }

    /// Нажатие, не пославшее запроса, обязано оставить след.
    ///
    /// Журнал завершений про это молчит: проверка, не породившая завершения,
    /// записи не заводит. Снаружи «нажал пять раз, и ничего» неотличимо
    /// от «кнопка сломана» — отличает только журнал проверок.
    func test_a_press_while_a_probe_is_in_flight_is_recorded() async {
        let checks = CheckLogStore(storage: InMemoryCheckLog())
        let h = makeDelayedHarness(snapshot: healthySnapshot(), checkLog: checks)

        h.vm.recheckNow()
        await h.probe.waitUntilStarted()

        h.vm.recheckNow()
        h.vm.recheckNow()
        await settle()

        let skipped = checks.all.filter { $0.outcome == .skippedProbeInFlight }
        XCTAssertEqual(skipped.count, 2, "оба холостых нажатия записаны")
        XCTAssertEqual(skipped.first?.trigger, .manual)
        XCTAssertEqual(
            skipped.first?.fingerprint, healthySnapshot().verdictFingerprint,
            "запись называет выход, на котором нажимали"
        )
    }

    /// Обновление цели само по себе никого не закрывает.
    ///
    /// Путь у claude и codex содержит номер версии, и обновление меняет его
    /// целиком. Правило переезжает на новую версию само, но переезд — это смена
    /// пути, а не смена вердикта: ревизию конфигурации он не поднимает
    /// и отпечаток сети не трогает. Иначе каждое обновление инструмента убивало
    /// бы его же сеанс.
    func test_updating_a_target_binary_kills_nothing() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome(primary: "KZ", confirmed: "KZ"))

        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()
        XCTAssertEqual(h.vm.phase.title, "Защищено")

        let killsBefore = h.signaler.killedBatches.count

        // Инструмент обновился: путь цели поменялся целиком.
        h.resolver.point(targetBundleID, to: "\(targetPath)-2.1.251")
        for _ in 0..<5 { h.vm.handle(.tick) }
        await settle()

        XCTAssertEqual(h.vm.phase.title, "Защищено", "вердикт не трогается")
        XCTAssertEqual(
            h.signaler.killedBatches.count, killsBefore,
            "обновление цели — не повод завершать её сеанс"
        )
    }

    /// Проба по кнопке не уступает автоматической.
    ///
    /// Нажатие создаёт пробу, но до своего запроса она доживает не сразу — между
    /// созданием и стартом есть точка подвеса. Любой автоматический повод,
    /// пришедший в этот зазор, снимал её, и она возвращалась по проверке отмены:
    /// ни запроса, ни ошибки, ни записи в журнале. Снаружи это ровно «нажал
    /// проверку и получил ничего».
    func test_an_automatic_probe_does_not_displace_the_one_requested_by_the_button() async {
        let checks = CheckLogStore(storage: InMemoryCheckLog())
        let h = makeDelayedHarness(snapshot: healthySnapshot(), checkLog: checks)

        h.vm.recheckNow()
        // Расписание подошло ровно в зазор — проба по кнопке ещё не стартовала.
        h.vm.handle(.geoSchedule)
        await h.probe.waitUntilStarted()

        await h.probe.resumeFirst(with: geoOutcome(primary: "KZ", confirmed: "KZ"))
        await settle()

        XCTAssertFalse(
            checks.all.filter { $0.trigger == .manual }.isEmpty,
            "нажатие обязано оставить след: запрос ушёл, был отбит или отброшен"
        )
    }

    /// Автоматические поводы пропускают пробу каждый такт — и в журнал это
    /// не идёт. Иначе за пять секунд ожидания ipinfo они вытеснили бы
    /// из полусотни записей ровно ту, ради которой журнал и ведётся.
    func test_automatic_triggers_do_not_flood_the_check_log_with_skips() async {
        let checks = CheckLogStore(storage: InMemoryCheckLog())
        let h = makeDelayedHarness(snapshot: healthySnapshot(), checkLog: checks)

        h.vm.handle(.networkPath)
        await h.probe.waitUntilStarted()

        for _ in 0..<10 { h.vm.handle(.tick) }
        await settle()

        XCTAssertTrue(
            checks.all.allSatisfy { $0.outcome != .skippedProbeInFlight },
            "пропуски автоматических поводов — рабочее состояние, а не событие"
        )
    }

    /// Остановленная охрана не оживает от ответа пробы, которая была в полёте.
    ///
    /// `stop()` снимает задачу пробы, но запрос к ipinfo уже ушёл. Применить его
    /// ответ значило бы заново поднять сторожевой таймер у выключённого приложения.
    func test_a_probe_answering_after_stop_does_not_revive_the_guard() async {
        let h = makeDelayedHarness(snapshot: healthySnapshot())

        h.vm.handle(.networkPath)
        await h.probe.waitUntilStarted()
        XCTAssertEqual(h.vm.phase.title, "Проверка")

        h.vm.stop()
        await h.probe.resumeFirst(with: geoOutcome(primary: "KZ", confirmed: "KZ"))
        await settle()

        // Остановка гасит и фазу: цели возобновлены, и отсчёт до потолка считать
        // больше некому. Применённый ответ дал бы «Защищено» и показания на экране —
        // ни того, ни другого быть не должно.
        XCTAssertEqual(h.vm.phase.title, "Выключено", "остановленная охрана фазу за собой не тянет")
        XCTAssertNil(h.vm.pauseDeadline, "стоящих целей нет — нет и отсчёта")
        XCTAssertNil(
            h.vm.lastReading,
            "ответ после остановки к состоянию не применяется"
        )
    }

    /// Состоявшаяся проверка пишется с трассами сервисов и длительностью:
    /// по ним видно, ушёл ли запрос и что ответили.
    func test_a_completed_check_is_recorded_with_its_traces() async {
        let checks = CheckLogStore(storage: InMemoryCheckLog())
        let h = makeDelayedHarness(snapshot: healthySnapshot(), checkLog: checks)

        h.vm.recheckNow()
        await h.probe.waitUntilStarted()
        await h.probe.resumeFirst(with: geoOutcome(primary: "KZ", confirmed: "KZ"))
        await settle()

        let answered = checks.all.first { $0.outcome == .answered }
        XCTAssertNotNil(answered, "успешная проверка по кнопке пишется")
        XCTAssertEqual(answered?.trigger, .manual)
        XCTAssertEqual(answered?.ip, "203.0.113.28")
        XCTAssertEqual(answered?.country, "KZ")
        XCTAssertFalse(answered?.services.isEmpty ?? true, "трассы сервисов на месте")
        XCTAssertNotNil(answered?.durationMilliseconds)
    }

    /// Пачка событий сети не плодит проб и не выбрасывает ответ.
    ///
    /// Раньше второе событие снимало первую пробу, и её ответ отбрасывался — так
    /// охрана защищалась от устаревших показаний. Защита оказалась дороже угрозы:
    /// пока вердикт несвеж, события и такты идут непрерывно, и на медленном канале
    /// ответ не доезжал никогда. Теперь пробу никто не снимает, а от чужих показаний
    /// защищает отпечаток — путь тот же, значит ответ про нас, и он применяется.
    func test_a_burst_of_network_events_neither_multiplies_nor_discards_the_probe() async {
        let h = makeDelayedHarness(snapshot: healthySnapshot())

        h.vm.handle(.networkPath)
        await h.probe.waitUntilStarted()
        h.vm.handle(.networkPath)
        h.vm.handle(.networkPath)
        await settle()

        let starts = await h.probe.starts()
        XCTAssertEqual(starts, 1, "пачка событий — одна проба")

        await h.probe.resumeFirst(with: geoOutcome())
        await settle()

        XCTAssertEqual(h.vm.phase.title, "Защищено", "путь тот же — ответ про нас")
    }

    func test_old_config_probe_result_is_ignored_after_blacklist_change() async {
        let h = makeDelayedHarness(snapshot: healthySnapshot())

        h.vm.handle(.networkPath)
        await h.probe.waitUntilStarted()

        h.settings.blockedIPRangeTexts = ["203.0.113.0/24"]
        await settle()

        await h.probe.resumeFirst(with: geoOutcome())
        await settle()

        XCTAssertEqual(h.vm.phase.title, "Проверка")
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

        XCTAssertEqual(h.vm.phase.title, "Проверка")
    }

    /// Ужесточение whitelist на работающей цели: страна выхода перестаёт быть
    /// разрешённой, и цель обязана быть завершена, а причина — попасть в журнал
    /// человеческим текстом.
    func test_tightening_the_whitelist_kills_a_running_target() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome())

        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()
        XCTAssertEqual(h.vm.phase.title, "Защищено")

        h.settings.allowedCountryCodes = ["DE"]
        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()

        XCTAssertEqual(h.vm.phase, .danger(.notWhitelistedCountry("KZ")))
        XCTAssertEqual(h.signaler.killedBatches.last, [500, 501])
        // Пауза холодного старта к этому моменту снята вердиктом, и завершение —
        // самостоятельный эпизод со своей причиной, а не исход стояния.
        XCTAssertEqual(h.log.events.first?.kind, .terminated)
        XCTAssertEqual(
            h.log.events.first?.reasonText,
            UnsafeEvidence.notWhitelistedCountry("KZ").displayText
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
        XCTAssertEqual(h.signaler.killedBatches, [[500]])

        h.settings.targets = [targetBundleID, "nano"]

        XCTAssertEqual(
            h.signaler.killedBatches.count, 2,
            "добавленная цель должна быть завершена сразу, а не на следующем тике"
        )
        XCTAssertEqual(h.signaler.killedBatches.last, [500, 600])
    }

    func test_choosing_a_vpn_app_that_is_not_running_kills_immediately() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome())
        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()
        XCTAssertEqual(h.vm.phase.title, "Защищено")

        h.settings.vpnAppRule = "com.example.absent"

        XCTAssertEqual(h.vm.phase, .danger(.vpnAppNotRunning))
        XCTAssertFalse(h.signaler.killedBatches.isEmpty)
    }

    func test_routine_tick_keeps_safe_state_while_verdict_is_fresh() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome())
        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()
        let batchesAfterFirstVerdict = h.signaler.killedBatches.count

        h.vm.handle(.tick)

        XCTAssertEqual(
            h.vm.phase.title, "Защищено",
            "штатный тик при неизменном снимке и настройках не обязан ронять цели"
        )
        await h.vm.awaitPendingProbe()
        XCTAssertEqual(h.signaler.killedBatches.count, batchesAfterFirstVerdict)
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
        XCTAssertEqual(h.vm.phase.title, "Защищено")
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
        let batchesAfterFirstVerdict = h.signaler.killedBatches.count

        h.network.snapshotValue = NetworkSnapshot(
            outgoing: OutgoingRoute(interface: "utun6", address: "198.18.0.1")
        )
        h.vm.handle(.networkPath)

        XCTAssertEqual(
            h.vm.phase.title, "Защищено",
            "чужой туннель не повод объявлять подключение непроверенным"
        )
        await h.vm.awaitPendingProbe()
        XCTAssertEqual(h.signaler.killedBatches.count, batchesAfterFirstVerdict)
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

        XCTAssertEqual(h.vm.phase.title, "Проверка")
    }

    func test_manual_recheck_does_not_kill_targets_on_a_healthy_vpn() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome())
        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()
        let batchesAfterFirstVerdict = h.signaler.killedBatches.count

        h.vm.recheckNow()

        XCTAssertEqual(
            h.vm.phase.title, "Защищено",
            "нажатие кнопки — не повод объявлять подключение непроверенным"
        )
        await h.vm.awaitPendingProbe()
        XCTAssertEqual(h.signaler.killedBatches.count, batchesAfterFirstVerdict)
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
        XCTAssertEqual(h.vm.phase.title, "Проверка")

        h.vm.recheckNow()
        await h.probe.waitUntilStarted(atLeast: 2)
        await h.probe.resumeFirst(with: geoOutcome())
        await h.vm.awaitPendingProbe()

        XCTAssertEqual(
            h.vm.phase.title, "Защищено",
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
        XCTAssertEqual(h.vm.phase.title, "Защищено")
        let batchesAfterVerdict = h.signaler.batches.count

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

        XCTAssertEqual(
            h.vm.phase.title, "Помехи",
            "адрес тот же — перепроверять нечего, но зелёный тут врал бы"
        )
        XCTAssertEqual(h.vm.phase.action, .run, "цели работают")
        XCTAssertEqual(h.signaler.batches.count, batchesAfterVerdict, "ни паузы, ни завершения")
        h.vm.stop()
    }

    /// Адрес сменился, а страны для него никто не назвал — вердикта нет, и снисхождения тоже:
    /// цели встают немедленно, без терпимости, но не завершаются.
    func test_silent_ipinfo_with_a_new_address_pauses_without_tolerance() async {
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
            h.vm.phase.title,
            "Пауза",
            "новый адрес не наследует страну прошлого"
        )
        XCTAssertEqual(h.signaler.batches.last?.signal, .stop)
        XCTAssertTrue(h.signaler.killedBatches.isEmpty, "смена адреса — не доказательство утечки")
        h.vm.stop()
    }

    /// Молчат оба сервиса — адреса нет вовсе, доказывать нечем.
    ///
    /// Терпимость к молчанию стоит между первой неудачной пробой и паузой:
    /// пока вердикт установлен и отпечаток не менялся, `Constants.silenceToleranceProbes`
    /// проб подряд ничего не меняют — это «Помехи». Цели встают со следующей,
    /// и встают, а не умирают.
    func test_silence_from_both_services_pauses_after_tolerance() async {
        let h = makeDelayedHarness(snapshot: healthySnapshot())
        h.vm.handle(.networkPath)
        await h.probe.waitUntilStarted()
        await h.probe.resumeFirst(with: geoOutcome())
        await h.vm.awaitPendingProbe()
        let batchesAfterVerdict = h.signaler.batches.count

        h.vm.handle(.geoSchedule)
        await h.probe.waitUntilStarted(atLeast: 2)
        await h.probe.resumeFirst(with: .unavailable("таймаут запроса"))
        await h.vm.awaitPendingProbe()
        XCTAssertEqual(
            h.vm.phase.title, "Помехи",
            "первое молчание в пределах терпимости целей не трогает"
        )
        XCTAssertEqual(h.signaler.batches.count, batchesAfterVerdict, "ни одного сигнала")

        await spendSilenceTolerance(h, after: 2)

        XCTAssertEqual(h.vm.phase.title, "Пауза")
        XCTAssertEqual(h.signaler.batches.last?.signal, .stop)
        XCTAssertTrue(h.signaler.killedBatches.isEmpty, "молчание сервисов не завершает цели")
        h.vm.stop()
    }

    /// Запись эпизода 19:31 несла адрес и страну прошлого вердикта под причиной «таймаут»
    /// без пометки, что это прошлое. Плоские поля не меняем — пометка едет в diagnostics.
    func test_silence_after_a_verdict_marks_the_readings_as_established() async {
        let harness = makeDelayedHarness(snapshot: healthySnapshot())
        harness.vm.start()
        await harness.probe.waitUntilStarted()
        await harness.probe.resumeFirst(with: geoOutcome())
        await harness.vm.awaitPendingProbe()

        await spendSilenceTolerance(harness, after: 1)

        let event = harness.log.events.first
        XCTAssertEqual(event?.ip, "203.0.113.28", "плоские поля остаются прошлым чтением")
        XCTAssertEqual(event?.diagnostics?.verdictOrigin, .established)
    }

    func test_a_fresh_blocked_country_marks_the_readings_as_current() async {
        let harness = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome(primary: "RU", confirmed: "RU"))
        harness.vm.start()
        await harness.vm.awaitPendingProbe()

        XCTAssertEqual(harness.log.events.first?.diagnostics?.verdictOrigin, .current)
    }

    /// Происхождение показаний не приклеивается к следующему эпизоду.
    ///
    /// Прежний флаг `decisionCameFromProbe` гаснул не на всех путях, и эпизод,
    /// вызванный не пробой, а сменой пути, наследовал его от давно отвеченной пробы:
    /// устаревшее чтение подписывалось как «текущее». Теперь происхождение приходит
    /// от контроллера с каждой применённой фазой.
    func test_the_origin_of_the_readings_does_not_stick_to_the_next_episode() async {
        let h = makeDelayedHarness(snapshot: healthySnapshot())
        h.vm.start()
        await h.probe.waitUntilStarted()
        await h.probe.resumeFirst(with: geoOutcome())
        await h.vm.awaitPendingProbe()
        XCTAssertEqual(h.vm.phase.title, "Защищено")

        // Подтверждения нет — непроверенность, но терпимость держит первые пробы:
        // цели встают, только когда она исчерпана.
        let started = await spendSilenceTolerance(h, after: 1, answering: geoOutcome(confirmed: nil))

        XCTAssertEqual(h.vm.phase.title, "Пауза")
        XCTAssertEqual(
            h.log.events.first?.diagnostics?.verdictOrigin, .current,
            "решение принято прямо по ответу пробы"
        )

        // Пауза снята полноценным вердиктом — следующий эпизод начинается с нуля.
        h.vm.handle(.geoSchedule)
        await h.probe.waitUntilStarted(atLeast: started + 1)
        await h.probe.resumeFirst(with: geoOutcome())
        await h.vm.awaitPendingProbe()
        XCTAssertEqual(h.vm.phase.title, "Защищено")

        h.network.snapshotValue = directSnapshot()
        h.vm.handle(.networkPath)

        XCTAssertEqual(h.log.events.first?.kind, .paused)
        XCTAssertNil(
            h.log.events.first?.diagnostics?.verdictOrigin,
            "эпизод вызван сменой пути, а не только что ответившей пробой"
        )
        // Смена пути гасит показания целиком (`onReport(nil)`): экран не имеет права
        // показывать страну туннеля, которого уже нет, — а вместе с ней подписывать
        // в записи нечего. Разбор свежести остаётся в `diagnostics.staleness`.
        XCTAssertNil(h.log.events.first?.ip)
        XCTAssertEqual(h.log.events.first?.diagnostics?.staleness?.cause, .networkChanged)
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

        XCTAssertEqual(h.vm.phase.title, "Помехи")
        XCTAssertEqual(h.vm.statusColor, .yellow)
        XCTAssertEqual(h.vm.currentCountryCode, "KZ", "страна известна: адрес доказанно тот же")
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
        XCTAssertEqual(h.vm.phase.title, "Защищено")

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

        XCTAssertEqual(h.vm.phase.title, "Проверка")
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

    /// Пауза приходит раньше вердикта, поэтому в журнал первым попадает
    /// «подключение ещё не проверено» — ответ «пока не знаю». Через миг вердикт
    /// готов, и завершать уже нечего: новой записи не будет, а исход эпизода
    /// обязан быть дописан — иначе журнал навсегда сохраняет отговорку вместо
    /// того, из-за чего цели и умерли.
    func test_journal_entry_of_an_episode_gets_the_settled_reason() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome(primary: "RU"))

        h.vm.handle(.networkPath)

        XCTAssertEqual(h.vm.phase.title, "Проверка")
        XCTAssertEqual(h.log.events.count, 2, "два остановленных процесса — две записи")
        XCTAssertEqual(Set(h.log.events.map(\.kind)), [.paused])
        XCTAssertEqual(Set(h.log.events.map(\.episodeID)).count, 1, "и один эпизод на них")
        XCTAssertEqual(
            Set(h.log.events.map(\.reasonText)),
            ["Подключение ещё не проверено: вердикта ещё не было"]
        )

        await h.vm.awaitPendingProbe()

        XCTAssertEqual(h.vm.phase, .danger(.blockedCountry(code: "RU", source: "ipinfo")))
        XCTAssertEqual(h.log.events.count, 2, "тем же pid новых записей не заводят")
        XCTAssertEqual(Set(h.log.events.map(\.episodeID)).count, 1)
        XCTAssertEqual(
            Set(h.log.events.map(\.resolutionText)),
            ["завершено по доказательству: Обнаружена страна RU по данным ipinfo"]
        )
        XCTAssertEqual(Set(h.log.events.map(\.country)), ["RU"], "исход принёс показания вердикта")
        XCTAssertEqual(Set(h.log.events.map(\.ip)), ["203.0.113.28"])
        XCTAssertEqual(h.signaler.killedBatches, [[500, 501]], "SIGKILL один — по доказательству")
    }

    /// Запись паузы описывает процесс целиком, включая признак потомка: именно потомки
    /// объясняют, почему у одной цели десятки записей.
    func test_pause_records_describe_descendants_as_such() {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome(), processes: [
            .init(pid: 500, parentPID: 1, executablePath: "\(targetPath)/Contents/MacOS/Target"),
            .init(pid: 501, parentPID: 500, executablePath: "/usr/bin/curl"),
            .init(pid: 700, executablePath: "\(vpnAppPath)/Contents/MacOS/Happ"),
        ])

        h.vm.handle(.networkPath)

        let child = h.log.events.first { $0.pid == 501 }
        XCTAssertEqual(child?.kind, .paused)
        XCTAssertEqual(child?.matchedBy, .descendant)
        XCTAssertEqual(child?.parentPID, 500)
        XCTAssertEqual(child?.executablePath, "/usr/bin/curl")
        XCTAssertEqual(h.log.events.first { $0.pid == 500 }?.matchedBy, .rule)
    }

    /// Причина «подключение ещё не проверено» без разбора неотличима от «изменили
    /// настройки»: и то, и другое обнуляет свежесть вердикта. Запись обязана
    /// сказать, что именно изменилось и на что.
    func test_pending_episode_records_what_lost_the_freshness() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome(primary: "KZ", confirmed: "KZ"))

        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()
        XCTAssertEqual(h.vm.phase.title, "Защищено")

        h.network.snapshotValue = directSnapshot()
        h.vm.handle(.networkPath)

        XCTAssertEqual(h.log.events.first?.kind, .paused, "цели стоят, а не завершены")
        let staleness = h.log.events.first?.diagnostics?.staleness
        XCTAssertEqual(staleness?.cause, .networkChanged, "сменился выход, а не настройки")
        XCTAssertNotEqual(staleness?.previousFingerprint, staleness?.fingerprint)
        XCTAssertEqual(staleness?.fingerprint, directSnapshot().verdictFingerprint)
    }

    /// Правка настроек свежесть вердикта больше не обнуляет (п. 11): вердикт — знание
    /// о сети, и от состава списков он не зависит. Решение пересчитывается по
    /// установленному чтению синхронно — без пробы, без паузы и без записи в журнале.
    ///
    /// До задачи 14 такая правка объявляла fail-closed и заводила эпизод с причиной
    /// `configurationChanged`; из-за этого пользователь терял цели, поправив список.
    func test_settings_change_keeps_the_verdict_and_writes_no_episode() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome(primary: "KZ", confirmed: "KZ"))

        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()
        XCTAssertEqual(h.vm.phase.title, "Защищено")
        let eventsAfterVerdict = h.log.events.count
        let killsAfterVerdict = h.signaler.killedBatches.count
        let callsAfterVerdict = await h.probe.calls()

        h.settings.blockedCountryCodes = ["DE"]
        h.vm.handle(.tick)
        await h.vm.awaitPendingProbe()

        XCTAssertEqual(h.vm.phase.title, "Защищено", "правка списков вердикт не обесценивает")
        XCTAssertEqual(h.log.events.count, eventsAfterVerdict, "эпизода нет: цели не трогали")
        XCTAssertEqual(h.signaler.killedBatches.count, killsAfterVerdict)
        let calls = await h.probe.calls()
        XCTAssertEqual(calls, callsAfterVerdict, "правка настроек пробы не просит: путь тот же")
    }

    /// Свежесть, потерянная в момент смены пути, установившей новый вердикт, не
    /// имеет права сопровождать эпизод более позднего таймаута: `lastStaleness`
    /// относится только к тому единственному fail-closed объявлению, ради
    /// которого посчитан, а не ко всем эпизодам до следующей смены пути.
    func test_timeout_after_a_settled_verdict_carries_no_stale_staleness() async {
        let h = makeDelayedHarness(snapshot: healthySnapshot())
        h.vm.start()
        await h.probe.waitUntilStarted()
        await h.probe.resumeFirst(with: geoOutcome())
        await h.vm.awaitPendingProbe()
        XCTAssertEqual(h.vm.phase.title, "Защищено")

        h.network.snapshotValue = directSnapshot()
        h.vm.handle(.networkPath)
        XCTAssertEqual(
            h.log.events.first?.diagnostics?.staleness?.cause, .networkChanged,
            "объявление fail-closed действительно вызвано сменой пути"
        )

        await h.probe.waitUntilStarted(atLeast: 2)
        await h.probe.resumeFirst(with: geoOutcome())
        await h.vm.awaitPendingProbe()
        XCTAssertEqual(h.vm.phase.title, "Защищено", "вердикт на новом пути состоялся")

        await spendSilenceTolerance(h, after: 2)

        XCTAssertEqual(h.vm.phase.title, "Пауза")
        XCTAssertNil(
            h.log.events.first?.diagnostics?.staleness,
            "таймаут по установленному вердикту не наследует смену пути из прошлого эпизода"
        )
    }

    /// Сырые ответы гео-сервисов доезжают до записи: разобранный ответ уже прошёл
    /// через наши предположения, и случай, где предположение неверно, по нему не виден.
    func test_record_carries_the_raw_answers_of_geo_services() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome(primary: "RU"))

        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()

        let services = h.log.events.first?.diagnostics?.services ?? []
        XCTAssertFalse(services.isEmpty, "трассы обязаны доехать до журнала")
        XCTAssertTrue(services.contains { $0.service == "ipinfo" })
        XCTAssertTrue(
            services.allSatisfy { !$0.url.lowercased().contains("token") },
            "токен в выгрузку попадать не должен"
        )
    }

    /// Самый частый и самый непонятный для пользователя случай: вердикта нет,
    /// цели встали, а через миг проверка сказала «всё в порядке». Запись обязана
    /// сказать, чем это кончилось, — без исхода она навсегда остаётся с отговоркой,
    /// и пауза выглядит случайной.
    func test_episode_that_ends_safe_records_how_it_ended() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome(primary: "KZ", confirmed: "KZ"))

        h.vm.handle(.networkPath)
        XCTAssertEqual(
            Set(h.log.events.map(\.reasonText)),
            ["Подключение ещё не проверено: вердикта ещё не было"]
        )
        XCTAssertNil(h.log.events.first?.resolutionText, "пока вердикта нет, исход неизвестен")

        await h.vm.awaitPendingProbe()

        XCTAssertEqual(h.vm.phase.title, "Защищено")
        XCTAssertEqual(
            h.log.events.first?.resolutionText,
            "возобновлено: проверка подтвердила безопасный выход: 203.0.113.28, KZ"
        )
        XCTAssertEqual(Set(h.log.events.map(\.kind)), [.paused])
        XCTAssertEqual(h.log.events.first?.ip, "203.0.113.28")
        XCTAssertEqual(h.log.events.first?.country, "KZ")
        XCTAssertEqual(h.signaler.batches.map(\.signal), [.stop, .resume])
    }

    /// Уточнение — про один эпизод. Новое падение после возврата к жизни обязано
    /// заводить свою запись, а не переписывать прошлую.
    func test_a_new_episode_does_not_rewrite_the_previous_entry() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome())

        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()
        XCTAssertEqual(h.vm.phase.title, "Защищено")
        XCTAssertEqual(h.log.events.count, 2)
        let firstEpisode = h.log.events[0].episodeID

        h.network.snapshotValue = directSnapshot()
        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()

        XCTAssertEqual(h.log.events.count, 4, "второй эпизод — свои записи")
        XCTAssertEqual(Set(h.log.events.map(\.episodeID)).count, 2)
        XCTAssertEqual(h.log.events.last?.episodeID, firstEpisode, "прошлый эпизод остался внизу")
        XCTAssertEqual(Set(h.log.events.map(\.kind)), [.paused])
        XCTAssertEqual(
            h.log.events.last?.resolutionText,
            "возобновлено: проверка подтвердила безопасный выход: 203.0.113.28, KZ",
            "исход прошлого эпизода не переписан вторым"
        )
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
            eventLog: EventLogStore(storage: InMemoryEventLog()),
            snapshotReader: StubSnapshotReader(snapshotValue: healthySnapshot()),
            geoProbe: StubGeoProbe(geoOutcome()),
            locator: locator,
            resolver: StubResolver(mapping: resolverMapping),
            signaler: SpySignaler(),
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
            eventLog: EventLogStore(storage: InMemoryEventLog()),
            snapshotReader: StubSnapshotReader(snapshotValue: healthySnapshot()),
            geoProbe: StubGeoProbe(geoOutcome()),
            locator: StubLocator(bundlePaths: [targetBundleID: targetPath], processes: processes),
            resolver: StubResolver(mapping: [targetBundleID: targetPath, vpnAppID: vpnAppPath]),
            signaler: SpySignaler(),
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

        XCTAssertEqual(h.vm.phase, .danger(.vpnAppNotRunning))
        XCTAssertEqual(h.signaler.killedBatches, [[500, 501]], "убиты только процессы цели")
        let probeCalls = await h.probe.calls()
        XCTAssertEqual(probeCalls, 0, "сетевая проба не должна была запускаться")
    }

    /// Трафик ушёл мимо туннеля — для охраны это смена состояния сети:
    /// прежний вердикт недействителен, и цели завершаются до ответа сети.
    func test_traffic_moving_off_the_tunnel_invalidates_the_verdict() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome())
        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()
        XCTAssertEqual(h.vm.phase.title, "Защищено")

        h.network.snapshotValue = directSnapshot()
        h.vm.handle(.networkPath)

        XCTAssertEqual(h.vm.phase.title, "Проверка")
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

        let signaler = SpySignaler()
        let log = EventLogStore(storage: InMemoryEventLog())
        let vm = GuardVM(
            settings: settings,
            eventLog: log,
            snapshotReader: StubSnapshotReader(snapshotValue: healthySnapshot()),
            geoProbe: StubGeoProbe(geoOutcome()),
            locator: locator,
            resolver: StubResolver(mapping: [targetBundleID: targetPath, vpnAppID: vpnAppPath]),
            signaler: signaler,
            notifier: SpyNotifier(),
            events: ManualEventSource(),
            debounceInterval: 0.01
        )

        vm.handle(.networkPath)
        await vm.awaitPendingProbe()
        XCTAssertEqual(vm.phase.title, "Защищено")

        locator.processes = processesWithoutVPNApp
        vm.handle(.appTerminated(bundleID: vpnAppID))

        XCTAssertEqual(vm.phase, .danger(.vpnAppNotRunning))
        XCTAssertEqual(signaler.killedBatches.last, [500, 501], "убиты цели, но не сам клиент")
        // Доказательство пришло к работающим целям: пауза кончилась вердиктом раньше,
        // и эта запись — не исход эпизода паузы, а полноценное завершение.
        XCTAssertEqual(log.events.first?.kind, .terminated)
        XCTAssertEqual(log.events.first?.reasonText, "VPN-приложение не запущено")
    }

    /// Запуск VPN-клиента пересчитывает вердикт сразу, как и его закрытие.
    ///
    /// Закрытие обрабатывалось, запуск — нет: у события запуска стоит проверка
    /// «это цель?», а VPN-приложение целью не бывает — его выбор снимает его
    /// из целей. Событие уходило в никуда, и охрана узнавала о поднявшемся
    /// клиенте только следующим тактом.
    func test_launching_the_vpn_app_re_evaluates_at_once() async {
        let locator = MutableLocator(
            bundlePaths: [targetBundleID: targetPath, vpnAppID: vpnAppPath],
            processes: processesWithoutVPNApp
        )
        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        settings.isEnabled = true
        settings.vpnAppRule = vpnAppID
        settings.targets = [targetBundleID]

        let vm = GuardVM(
            settings: settings,
            eventLog: EventLogStore(storage: InMemoryEventLog()),
            snapshotReader: StubSnapshotReader(snapshotValue: healthySnapshot()),
            geoProbe: StubGeoProbe(geoOutcome()),
            locator: locator,
            resolver: StubResolver(mapping: [targetBundleID: targetPath, vpnAppID: vpnAppPath]),
            signaler: SpySignaler(),
            notifier: SpyNotifier(),
            events: ManualEventSource(),
            debounceInterval: 0.01
        )

        vm.handle(.networkPath)
        await vm.awaitPendingProbe()
        XCTAssertEqual(vm.phase, .danger(.vpnAppNotRunning))

        locator.processes = defaultProcesses
        vm.handle(.appLaunched(bundleID: vpnAppID))
        await vm.awaitPendingProbe()

        XCTAssertEqual(vm.phase.title, "Защищено", "клиент поднялся — вердикт пересчитан")
    }

    /// Выбранное VPN-приложение не завершается никогда: охрана, убившая свой
    /// источник защиты, оставила бы состояние необратимым.
    func test_the_vpn_app_is_never_killed() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome(primary: "RU"))

        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()

        XCTAssertEqual(h.vm.phase, .danger(.blockedCountry(code: "RU", source: "ipinfo")))
        XCTAssertFalse(h.signaler.killedBatches.isEmpty, "цели обязаны быть завершены")
        XCTAssertFalse(
            h.signaler.batches.flatMap(\.pids).contains(700),
            "процесс VPN-клиента не должен попадать ни под нож, ни под паузу"
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

        let signaler = SpySignaler()
        let probe = StubGeoProbe(geoOutcome())
        let vm = GuardVM(
            settings: settings,
            eventLog: EventLogStore(storage: InMemoryEventLog()),
            snapshotReader: StubSnapshotReader(snapshotValue: healthySnapshot()),
            geoProbe: probe,
            locator: locator,
            resolver: StubResolver(mapping: [
                targetBundleID: targetPath,
                vpnAppID: vpnAppPath,
                "nano": "/usr/bin/pico",
            ]),
            signaler: signaler,
            notifier: SpyNotifier(),
            events: ManualEventSource(),
            debounceInterval: 0.01
        )

        vm.handle(.networkPath)
        await vm.awaitPendingProbe()
        XCTAssertEqual(vm.phase.title, "Защищено")
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

        let signaler = SpySignaler()
        let vm = GuardVM(
            settings: settings,
            eventLog: EventLogStore(storage: InMemoryEventLog()),
            snapshotReader: StubSnapshotReader(snapshotValue: healthySnapshot()),
            geoProbe: StubGeoProbe(geoOutcome()),
            locator: locator,
            resolver: StubResolver(mapping: [
                targetBundleID: targetPath,
                vpnAppID: vpnAppPath,
                "nano": "/usr/bin/pico",
            ]),
            signaler: signaler,
            notifier: SpyNotifier(),
            events: ManualEventSource(),
            debounceInterval: 0.01
        )

        vm.handle(.networkPath)
        XCTAssertEqual(vm.phase, .danger(.vpnAppNotRunning))

        settings.targets += ["nano"]

        XCTAssertTrue(
            signaler.killedBatches.flatMap { $0 }.contains(601),
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
            eventLog: EventLogStore(storage: InMemoryEventLog()),
            snapshotReader: StubSnapshotReader(snapshotValue: healthySnapshot()),
            geoProbe: StubGeoProbe(geoOutcome()),
            locator: ProcessRegistry(),
            resolver: TargetResolver(),
            signaler: SpySignaler(),
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

        XCTAssertEqual(h.vm.phase, .disabled)
        XCTAssertTrue(h.signaler.batches.isEmpty, "выключенная охрана не трогает процессы вовсе")
    }

    func test_healthy_network_ends_in_safe_state_after_verification() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome())

        h.vm.handle(.networkPath)
        XCTAssertEqual(
            h.vm.phase.title, "Проверка",
            "пока страна не подтверждена, цели стоят"
        )

        await h.vm.awaitPendingProbe()

        XCTAssertEqual(h.vm.phase.title, "Защищено")
        XCTAssertEqual(h.vm.lastReading?.ip, "203.0.113.28")
        XCTAssertEqual(h.vm.statusColor, .green)
        XCTAssertEqual(h.vm.currentCountryCode, "KZ")
    }

    /// Доказательство пришло к целям, которые уже стояли с холодного старта: SIGKILL
    /// один, записей столько же, сколько было под паузой, и уведомление одно — цели
    /// завершены один раз, а не дважды.
    func test_blocked_country_kills_and_records_event() async {
        let h = makeHarness(
            snapshot: healthySnapshot(),
            geo: geoOutcome(primary: "RU", confirmed: "RU")
        )

        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()

        XCTAssertEqual(h.vm.phase, .danger(.blockedCountry(code: "RU", source: "ipinfo")))
        XCTAssertEqual(h.signaler.batches.map(\.signal), [.stop, .kill])
        XCTAssertEqual(h.signaler.killedBatches, [[500, 501]])

        XCTAssertEqual(h.log.events.count, 2, "два процесса — две записи, и обе от паузы")
        XCTAssertEqual(Set(h.log.events.map(\.episodeID)).count, 1)
        XCTAssertEqual(Set(h.log.events.map(\.kind)), [.paused])
        XCTAssertEqual(Set(h.log.events.map(\.country)), ["RU"])
        XCTAssertEqual(
            Set(h.log.events.map(\.resolutionText)),
            ["завершено по доказательству: \(UnsafeEvidence.blockedCountry(code: "RU", source: "ipinfo").displayText)"]
        )
        XCTAssertEqual(h.notifier.terminated.count, 1, "одно завершение — одно уведомление")
        XCTAssertEqual(
            h.notifier.terminated.first,
            "\(targetBundleID) ×2: Обнаружена страна RU по данным ipinfo"
        )
    }

    /// ipinfo ответил, подтверждения нет: доказательства утечки тоже нет — цели стоят,
    /// а статус жёлтый, потому что зелёный тут врал бы.
    func test_missing_confirmation_pauses_and_shows_yellow() async {
        let h = makeHarness(
            snapshot: healthySnapshot(),
            geo: geoOutcome(primary: "KZ", confirmed: nil)
        )

        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()

        XCTAssertEqual(h.vm.phase.title, "Проверка")
        XCTAssertEqual(h.vm.statusColor, .yellow)
        XCTAssertEqual(h.signaler.batches.map(\.signal), [.stop], "непроверенность ставит на паузу")
        XCTAssertTrue(h.signaler.killedBatches.isEmpty)
    }

    func test_geo_unavailable_pauses_and_shows_yellow_without_flag() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: .unavailable("timeout"))

        h.vm.handle(.networkPath)
        await h.vm.awaitPendingProbe()

        XCTAssertEqual(h.vm.phase.title, "Проверка")
        XCTAssertEqual(
            h.vm.statusColor, .yellow,
            "цели стоят, а не завершены: красный оставлен доказательству"
        )
        XCTAssertTrue(h.signaler.killedBatches.isEmpty)
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
        XCTAssertEqual(h.signaler.killedBatches.count, 1)

        h.vm.handle(.appLaunched(bundleID: targetBundleID))

        XCTAssertEqual(h.signaler.killedBatches.count, 2, "перезапущенная цель должна быть добита")
        XCTAssertEqual(Set(h.log.events.map(\.episodeID)).count, 1,
                       "те же pid по той же причине второго эпизода не заводят")
    }

    /// Цель, запустившаяся во время паузы, обязана встать вместе с остальными
    /// и попасть в тот же эпизод с той же причиной: эпизод паузы — один, пока цели стоят.
    func test_relaunch_while_paused_joins_the_same_episode() async {
        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        settings.isEnabled = true
        settings.vpnAppRule = vpnAppID
        settings.targets = [targetBundleID]

        let log = EventLogStore(storage: InMemoryEventLog())
        let locator = MutableLocator(
            bundlePaths: [targetBundleID: targetPath, vpnAppID: vpnAppPath],
            processes: [
                .init(pid: 500, executablePath: "\(targetPath)/Contents/MacOS/Target"),
                .init(pid: 700, executablePath: "\(vpnAppPath)/Contents/MacOS/Happ"),
            ]
        )
        let vm = GuardVM(
            settings: settings,
            eventLog: log,
            snapshotReader: StubSnapshotReader(snapshotValue: healthySnapshot()),
            geoProbe: StubGeoProbe(.unavailable("таймаут запроса")),
            locator: locator,
            resolver: StubResolver(mapping: [targetBundleID: targetPath, vpnAppID: vpnAppPath]),
            signaler: SpySignaler(),
            notifier: SpyNotifier(),
            events: ManualEventSource(),
            debounceInterval: 10
        )

        vm.handle(.networkPath)
        let originalReason = log.events.first?.reasonText
        XCTAssertEqual(originalReason, "Подключение ещё не проверено: вердикта ещё не было")
        XCTAssertEqual(log.events.first?.kind, .paused)
        let episode = log.events.first?.episodeID

        // Цель перезапущена с новым pid, пока вердикт всё ещё не установлен.
        locator.processes = [
            .init(pid: 777, executablePath: "\(targetPath)/Contents/MacOS/Target"),
            .init(pid: 700, executablePath: "\(vpnAppPath)/Contents/MacOS/Happ"),
        ]
        vm.handle(.appLaunched(bundleID: targetBundleID))

        XCTAssertEqual(log.events.count, 2, "цель, запущенная под паузой, остановлена и записана")
        XCTAssertEqual(log.events.first?.pid, 777)
        XCTAssertEqual(
            log.events.first?.reasonText, originalReason,
            "причина эпизода одна: текст состояния её не подменяет"
        )
        XCTAssertEqual(log.events.first?.kind, .paused)
        XCTAssertEqual(log.events.first?.episodeID, episode, "эпизод паузы один, пока цели стоят")
    }

    /// Тот же путь, но через сторожа: он срабатывает каждые
    /// `Constants.watchdogIntervalSeconds`, пока цели стоят, и обязан ставить
    /// новорождённых в тот же эпизод с той же причиной.
    func test_watchdog_pauses_newcomers_within_the_same_episode() async {
        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        settings.isEnabled = true
        settings.vpnAppRule = vpnAppID
        settings.targets = [targetBundleID]

        let log = EventLogStore(storage: InMemoryEventLog())
        let locator = MutableLocator(
            bundlePaths: [targetBundleID: targetPath, vpnAppID: vpnAppPath],
            processes: [
                .init(pid: 500, executablePath: "\(targetPath)/Contents/MacOS/Target"),
                .init(pid: 700, executablePath: "\(vpnAppPath)/Contents/MacOS/Happ"),
            ]
        )
        let probe = DelayedGeoProbe()
        let vm = GuardVM(
            settings: settings,
            eventLog: log,
            snapshotReader: StubSnapshotReader(snapshotValue: healthySnapshot()),
            geoProbe: probe,
            locator: locator,
            resolver: StubResolver(mapping: [targetBundleID: targetPath, vpnAppID: vpnAppPath]),
            signaler: SpySignaler(),
            notifier: SpyNotifier(),
            events: ManualEventSource(),
            // Проба не должна успеть уйти за время теста: иначе настоящий ответ
            // сменил бы текст причины сам по себе, и проверка была бы не о том.
            debounceInterval: 10
        )

        vm.handle(.networkPath)
        let originalReason = log.events.first?.reasonText
        XCTAssertEqual(originalReason, "Подключение ещё не проверено: вердикта ещё не было")
        let episode = log.events.first?.episodeID

        locator.processes = [
            .init(pid: 777, executablePath: "\(targetPath)/Contents/MacOS/Target"),
            .init(pid: 700, executablePath: "\(vpnAppPath)/Contents/MacOS/Happ"),
        ]
        try? await Task.sleep(for: .seconds(Constants.watchdogIntervalSeconds + 0.15))

        XCTAssertEqual(log.events.count, 2, "сторож обязан остановить процесс, запущенный под паузой")
        XCTAssertEqual(log.events.first?.pid, 777)
        XCTAssertEqual(
            log.events.first?.reasonText, originalReason,
            "сторож обязан переиспользовать причину эпизода, а не текст состояния"
        )
        XCTAssertEqual(log.events.first?.kind, .paused)
        XCTAssertEqual(log.events.first?.episodeID, episode)
        vm.stop()
    }

    func test_newly_launched_target_is_recorded_even_while_already_unsafe() async {

        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        settings.isEnabled = true
        settings.vpnAppRule = vpnAppID
        settings.targets = [targetBundleID]

        let signaler = SpySignaler()
        let log = EventLogStore(storage: InMemoryEventLog())
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
            signaler: signaler,
            notifier: SpyNotifier(),
            events: ManualEventSource(),
            debounceInterval: 0.01
        )

        vm.handle(.networkPath)
        XCTAssertEqual(log.events.count, 1)

        locator.processes = [.init(pid: 777, executablePath: "\(targetPath)/Contents/MacOS/Target")]
        vm.handle(.tick)

        XCTAssertEqual(log.events.count, 2, "новый pid обязан попасть в журнал")
        XCTAssertEqual(log.events.first?.pid, 777)
    }

    func test_launch_of_unrelated_app_is_ignored() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome(),
                            processes: processesWithoutVPNApp)
        h.vm.handle(.networkPath)

        h.vm.handle(.appLaunched(bundleID: "com.apple.TextEdit"))

        XCTAssertEqual(h.signaler.killedBatches.count, 1)
    }

    func test_eperm_is_surfaced_instead_of_being_swallowed() async {
        let h = makeHarness(snapshot: healthySnapshot(), geo: geoOutcome(),
                            processes: processesWithoutVPNApp)
        h.signaler.setError(EPERM, forPID: 500)

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

        XCTAssertTrue(h.signaler.killedBatches.isEmpty)
        XCTAssertTrue(h.log.events.isEmpty)
        XCTAssertEqual(h.vm.phase, .danger(.vpnAppNotRunning), "состояние всё равно небезопасное")
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

        XCTAssertEqual(h.signaler.killedBatches, [[700]], "убит pico, vim не тронут")
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

        XCTAssertEqual(h.signaler.killedBatches, [[800]], "посторонний Node-процесс не тронут")
    }

    func test_unknown_command_matches_nothing() async {
        let h = makeHarness(
            snapshot: healthySnapshot(),
            geo: geoOutcome(),
            processes: [.init(pid: 700, executablePath: "/usr/bin/pico")],
            executables: ["не-существует"]
        )

        h.vm.handle(.networkPath)

        XCTAssertTrue(h.signaler.killedBatches.isEmpty)
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

        let log = EventLogStore(storage: InMemoryEventLog())
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
            signaler: SpySignaler(),
            notifier: SpyNotifier(),
            events: ManualEventSource(),
            debounceInterval: 0.01
        )

        vm.handle(.networkPath)
        XCTAssertEqual(log.events.first?.kind, .terminated)
        XCTAssertEqual(log.events.first?.targetName, targetBundleID)

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
        XCTAssertEqual(h.vm.phase, .danger(.vpnAppNotRunning), "вердикт охраны кнопка не смягчает")
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
        XCTAssertEqual(h.vm.phase, .danger(.vpnAppNotRunning), "показания вердикт не смягчают")
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
        XCTAssertEqual(h.vm.phase, .disabled, "состояние охраны от кнопки не меняется")
    }

    // MARK: - Регрессия по журналу 2026-09-07 и п. 11

    /// 18:03:21Z: холодный старт, вердикт через 2 с. Цели стоят, а не умирают, и возобновляются.
    func test_episode_1803_cold_start_pauses_and_resumes_on_safe() async {
        let harness = makeDelayedHarness(snapshot: utun5Snapshot())
        harness.vm.start()

        XCTAssertEqual(harness.vm.phase.title, "Проверка")
        XCTAssertEqual(harness.signaler.batches.first?.signal, .stop)
        XCTAssertEqual(Set(harness.signaler.batches.first?.pids ?? []), [500, 501])
        XCTAssertEqual(harness.log.events.first?.kind, .paused)
        XCTAssertEqual(harness.log.events.first?.reasonText, "Подключение ещё не проверено: вердикта ещё не было")

        await harness.probe.waitUntilStarted()
        await harness.probe.resumeFirst(with: .resolved(GeoReading(
            ip: "91.224.74.177", primaryCountry: "KZ", confirmedCountry: "KZ", confirmSource: .freeipapi)))
        await harness.vm.awaitPendingProbe()

        XCTAssertEqual(harness.vm.phase.title, "Защищено")
        XCTAssertEqual(harness.signaler.batches.last?.signal, .resume)
        XCTAssertEqual(harness.signaler.batches.last?.pids, [501, 500], "потомок раньше родителя")
        XCTAssertFalse(harness.signaler.batches.contains { $0.signal == .kill }, "ни одного SIGKILL")
        XCTAssertEqual(
            harness.log.events.first?.resolutionText,
            "возобновлено: проверка подтвердила безопасный выход: 91.224.74.177, KZ"
        )
        XCTAssertTrue(harness.vm.pausedProcesses.isEmpty)
        harness.vm.stop()
    }

    /// 19:31:51Z: оба сервиса молчат три минуты при действующем вердикте и неизменном отпечатке.
    /// Терпимость — Помехи; затем Пауза; через 60 с — завершение по потолку.
    ///
    /// Порядковые номера проб и арифметика времени считаются по действующему редьюсеру:
    /// терпимость пропускает `Constants.silenceToleranceProbes` неудач и ставит на паузу
    /// на следующей, то есть на третьей.
    func test_episode_1931_silence_is_tolerated_then_paused_then_killed_at_the_ceiling() async {
        let clock = TestClock()
        let harness = makeDelayedHarness(snapshot: utun5Snapshot(), now: { clock.now })
        harness.vm.start()
        await harness.probe.waitUntilStarted()
        await harness.probe.resumeFirst(with: geoOutcome())
        await harness.vm.awaitPendingProbe()
        XCTAssertEqual(harness.vm.phase.title, "Защищено")
        let batchesBeforeSilence = harness.signaler.batches.count
        let eventsBeforeSilence = harness.log.events.count

        func failProbe(_ ordinal: Int) async {
            clock.advance(by: 5)
            harness.vm.handle(.geoSchedule)
            await harness.probe.waitUntilStarted(atLeast: ordinal)
            await harness.probe.resumeFirst(with: .unavailable("таймаут запроса"))
            await harness.vm.awaitPendingProbe()
        }

        await failProbe(2)
        XCTAssertEqual(harness.vm.phase.title, "Помехи")
        XCTAssertEqual(harness.signaler.batches.count, batchesBeforeSilence, "первая неудача ничего не трогает")

        await failProbe(3)
        XCTAssertEqual(harness.vm.phase.title, "Помехи", "терпимость держит вторую неудачу")
        XCTAssertEqual(harness.signaler.batches.count, batchesBeforeSilence)

        // Третья неудача — терпимость исчерпана: пауза началась на 15-й секунде.
        await failProbe(4)
        XCTAssertEqual(harness.vm.phase.title, "Пауза")
        XCTAssertEqual(harness.signaler.batches.last?.signal, .stop)
        XCTAssertEqual(harness.log.events.first?.kind, .paused)
        XCTAssertEqual(harness.log.events.first?.reasonText, "Не удалось определить внешний адрес: таймаут запроса")
        XCTAssertEqual(harness.log.events.first?.ip, "203.0.113.28", "плоские поля — прошлый вердикт")
        XCTAssertEqual(harness.log.events.first?.diagnostics?.verdictOrigin, .established)
        XCTAssertEqual(
            harness.vm.pauseDeadline?.timeIntervalSince(clock.now), Constants.pauseCeilingSeconds,
            "потолок отсчитывается от начала стояния"
        )

        for ordinal in 5...8 { await failProbe(ordinal) }
        XCTAssertEqual(harness.vm.phase.title, "Пауза", "молчание в пределах потолка ничего не меняет")
        XCTAssertFalse(harness.signaler.batches.contains { $0.signal == .kill })

        clock.advance(by: 41)   // 15 с до паузы + 5 × 4 + 41 = 61 с стояния
        harness.vm.handle(.tick)

        XCTAssertEqual(harness.vm.phase, .danger(.pauseExpired))
        XCTAssertEqual(harness.signaler.batches.last?.signal, .kill)
        XCTAssertEqual(harness.signaler.batches.last?.pids, [500, 501])
        XCTAssertEqual(harness.log.events.first?.kind, .paused, "повторных записей terminated нет")
        XCTAssertEqual(harness.log.events.first?.resolutionText, "завершено по потолку: Подтверждение не получено за 60 с")
        XCTAssertEqual(
            harness.log.events.count, eventsBeforeSilence + 2,
            "две записи паузы по молчанию, ни одной новой при завершении"
        )
        XCTAssertTrue(harness.log.events.allSatisfy { $0.kind == .paused }, "ни одной записи kind: terminated")
        XCTAssertTrue(harness.vm.pausedProcesses.isEmpty)
        harness.vm.stop()
    }

    /// п. 11: добавление цели при действующем вердикте не трогает ни запущенные, ни сеть.
    func test_adding_a_target_under_an_established_verdict_touches_nothing() async {
        let harness = makeHarness(snapshot: utun5Snapshot(), geo: geoOutcome())
        harness.vm.start()
        await harness.vm.awaitPendingProbe()
        XCTAssertEqual(harness.vm.phase.title, "Защищено")
        let probes = await harness.probe.calls()
        let batches = harness.signaler.batches.count
        let events = harness.log.events.count

        harness.settings.targets += ["nano"]

        XCTAssertEqual(harness.vm.phase.title, "Защищено")
        XCTAssertEqual(harness.signaler.batches.count, batches, "ни стопа, ни завершения")
        let probesAfter = await harness.probe.calls()
        XCTAssertEqual(probesAfter, probes, "пробы нет — вердикт в силе")
        XCTAssertEqual(harness.log.events.count, events, "нового эпизода нет")
    }

    /// Правка чёрного списка при действующем вердикте — переоценка: доказательство завершает сразу.
    /// Показания при этом взяты из прошлого вердикта, и запись обязана так и сказать.
    func test_blacklisting_the_current_country_terminates_by_reassessment() async {
        let harness = makeHarness(snapshot: utun5Snapshot(), geo: geoOutcome())
        harness.vm.start()
        await harness.vm.awaitPendingProbe()

        harness.settings.blockedCountryCodes = ["RU", "KZ"]

        XCTAssertEqual(harness.vm.phase, .danger(.blockedCountry(code: "KZ", source: "ipinfo")))
        XCTAssertEqual(harness.signaler.batches.last?.signal, .kill)
        XCTAssertEqual(harness.log.events.first?.kind, .terminated)
        XCTAssertEqual(harness.log.events.first?.reasonText, "Обнаружена страна KZ по данным ipinfo")
        XCTAssertEqual(
            harness.log.events.first?.diagnostics?.verdictOrigin, .established,
            "решение принято по прошлому вердикту, а не по только что ответившей пробе"
        )
    }

    /// Штатный выход снимает паузу: замороженных целей weto не оставляет.
    func test_stop_resumes_paused_targets() async {
        let harness = makeDelayedHarness(snapshot: utun5Snapshot())
        harness.vm.start()
        XCTAssertEqual(harness.signaler.batches.last?.signal, .stop)

        harness.vm.stop()

        XCTAssertEqual(harness.signaler.batches.last?.signal, .resume)
        XCTAssertEqual(
            harness.log.events.first?.resolutionText, "возобновлено: охрана остановлена",
            "исход эпизода дописан и при выходе"
        )
        XCTAssertTrue(harness.vm.pausedProcesses.isEmpty)
    }

    /// Фоновая терминальная цель получает пометку и уведомление с подсказкой про fg.
    func test_backgrounded_terminal_target_is_flagged_and_notified() async {
        let shell = ProcessSnapshot(pid: 100, parentPID: 1, executablePath: "/bin/zsh",
                                    processGroup: 100, terminalForegroundGroup: 100)
        let nano = ProcessSnapshot(pid: 200, parentPID: 100, executablePath: "/usr/bin/pico",
                                   processGroup: 200, terminalForegroundGroup: 100)
        let harness = makeDelayedHarness(snapshot: utun5Snapshot(),
                                         processes: [shell, nano] + defaultProcesses,
                                         executables: ["nano"])
        harness.vm.start()

        XCTAssertEqual(harness.vm.pausedProcesses.first { $0.pid == 200 }?.isBackgrounded, true)
        XCTAssertEqual(harness.notifier.backgrounded, ["nano"])
        XCTAssertFalse(harness.signaler.batches.first?.pids.contains(100) ?? true, "шелл фонового задания не трогаем")
        harness.vm.stop()
    }

    /// Потолок паузы виден интерфейсу только пока цели стоят.
    func test_pause_deadline_exists_only_while_the_targets_stand() async {
        let harness = makeDelayedHarness(snapshot: utun5Snapshot())
        harness.vm.start()

        XCTAssertEqual(
            harness.vm.pauseDeadline?.timeIntervalSince(harness.vm.phase.pausedSince ?? Date()),
            Constants.pauseCeilingSeconds
        )

        await harness.probe.waitUntilStarted()
        await harness.probe.resumeFirst(with: geoOutcome())
        await harness.vm.awaitPendingProbe()

        XCTAssertNil(harness.vm.pauseDeadline, "цели работают — отсчёта нет")
        harness.vm.stop()
    }

    /// Учёт остановленных, не прочитавшийся с диска, обязан оставить след: обязательство
    /// «вернуть остановленным SIGCONT» в этот запуск выполнено не было, и молчаливое
    /// пустое чтение неотличимо от «нечего возобновлять».
    func test_a_corrupted_stopped_ledger_leaves_a_trace_in_the_check_log() async {
        let checks = CheckLogStore(storage: InMemoryCheckLog())
        let harness = makeDelayedHarness(
            snapshot: utun5Snapshot(),
            checkLog: checks,
            ledger: StoppedLedger(storage: CorruptedStoppedLedger())
        )

        harness.vm.start()

        let trace = checks.all.first { $0.trigger == .startupRecovery }
        XCTAssertNotNil(trace, "старт с испорченным учётом обязан попасть в журнал проверок")
        XCTAssertEqual(trace?.outcome, .ledgerUnreadable)
        XCTAssertEqual(trace?.detail, "учёт остановленных процессов не прочитан: возобновлять нечего")
        harness.vm.stop()
    }

    /// Пилюля «Показать терминал» спрашивает границу про тот самый pid.
    func test_show_terminal_asks_the_locator_about_that_pid() {
        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        settings.isEnabled = true
        settings.vpnAppRule = vpnAppID
        settings.targets = [targetBundleID]

        let terminals = SpyTerminalLocator()
        let vm = GuardVM(
            settings: settings,
            eventLog: EventLogStore(storage: InMemoryEventLog()),
            snapshotReader: StubSnapshotReader(snapshotValue: utun5Snapshot()),
            geoProbe: StubGeoProbe(geoOutcome()),
            locator: StubLocator(
                bundlePaths: [targetBundleID: targetPath, vpnAppID: vpnAppPath],
                processes: defaultProcesses
            ),
            resolver: StubResolver(mapping: [targetBundleID: targetPath, vpnAppID: vpnAppPath]),
            signaler: SpySignaler(),
            terminalLocator: terminals,
            notifier: SpyNotifier(),
            events: ManualEventSource(),
            debounceInterval: 10
        )

        vm.showTerminal(for: 500)

        XCTAssertEqual(terminals.asked, [500])
    }

    // MARK: - Честность журнала: ревью задачи 15

    /// Завершение после «Помех» — первое завершение своего эпизода, а не «запуск запрещён».
    ///
    /// Дедупликация записей и причин снималась только на «Защищено», а «Помехи» — путь
    /// рабочий: 429 от ipinfo приходит регулярно, и адрес называет резервный сервис.
    /// Доказательство после них получало `kind: .launchBlocked`, а при совпавшем pid
    /// не давало ни записи, ни уведомления — ровно в тот момент, когда цели умирают.
    func test_a_kill_after_interference_is_a_first_kill_again() async {
        let locator = MutableLocator(
            bundlePaths: [targetBundleID: targetPath, vpnAppID: vpnAppPath],
            processes: defaultProcesses
        )
        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        settings.isEnabled = true
        settings.vpnAppRule = vpnAppID
        settings.targets = [targetBundleID]

        let notifier = SpyNotifier()
        let log = EventLogStore(storage: InMemoryEventLog())
        let probe = DelayedGeoProbe()
        let vm = GuardVM(
            settings: settings,
            eventLog: log,
            snapshotReader: StubSnapshotReader(snapshotValue: healthySnapshot()),
            geoProbe: probe,
            locator: locator,
            resolver: StubResolver(mapping: [targetBundleID: targetPath, vpnAppID: vpnAppPath]),
            signaler: SpySignaler(),
            notifier: notifier,
            events: ManualEventSource(),
            debounceInterval: 0
        )

        vm.handle(.networkPath)
        await probe.waitUntilStarted()
        await probe.resumeFirst(with: geoOutcome())
        await vm.awaitPendingProbe()
        XCTAssertEqual(vm.phase.title, "Защищено")

        // Клиент закрылся: доказательство и завершение.
        locator.processes = processesWithoutVPNApp
        vm.handle(.appTerminated(bundleID: vpnAppID))

        XCTAssertEqual(vm.phase, .danger(.vpnAppNotRunning))
        XCTAssertEqual(log.events.first?.kind, .terminated)
        XCTAssertEqual(notifier.terminated.count, 1)
        let firstEpisode = log.events.first?.episodeID
        let eventsAfterFirstKill = log.events.count

        // ipinfo молчит с 429, адрес называет резервный сервис — «Помехи»: цели работают,
        // и клиент к этому времени снова поднят.
        vm.handle(.geoSchedule)
        await probe.waitUntilStarted(atLeast: 2)
        locator.processes = defaultProcesses
        await probe.resumeFirst(with: .degraded(
            previous: GeoReading(ip: "203.0.113.28", primaryCountry: "KZ",
                                 confirmedCountry: "KZ", confirmSource: .freeipapi),
            detail: "HTTP 429"
        ))
        await vm.awaitPendingProbe()
        XCTAssertEqual(vm.phase.title, "Помехи")
        XCTAssertEqual(vm.phase.action, .run, "цели снова работают")

        // Клиент закрылся снова: те же pid и та же улика, но эпизод новый.
        locator.processes = processesWithoutVPNApp
        vm.handle(.appTerminated(bundleID: vpnAppID))

        XCTAssertEqual(vm.phase, .danger(.vpnAppNotRunning))
        XCTAssertEqual(log.events.first?.kind, .terminated,
                       "первое завершение эпизода — не «запуск запрещён»")
        XCTAssertNotEqual(log.events.first?.episodeID, firstEpisode, "и эпизод у него свой")
        XCTAssertEqual(log.events.count, eventsAfterFirstKill + 2,
                       "две записи на проход: обе цели описаны заново")
        XCTAssertEqual(notifier.terminated.count, 2, "пользователь узнаёт и о втором завершении")
    }

    /// Смена пути под паузой не оставляет эпизод с прежней причиной.
    ///
    /// Редьюсер переводит «Паузу» в «Проверку» и заново запускает отсчёт потолка,
    /// а эффекта не даёт — цели и так стоят. Записи эпизода при этом продолжали
    /// утверждать таймаут и не несли разбора свежести: по выгрузке выходило, что
    /// путь не менялся вовсе, а цели завершены по потолку неизвестно чьего стояния.
    func test_a_path_change_under_the_pause_refines_the_episode_to_its_new_cause() async {
        let clock = TestClock()
        let h = makeDelayedHarness(snapshot: healthySnapshot(), now: { clock.now })
        h.vm.start()
        await h.probe.waitUntilStarted()
        await h.probe.resumeFirst(with: geoOutcome())
        await h.vm.awaitPendingProbe()
        XCTAssertEqual(h.vm.phase.title, "Защищено")

        await spendSilenceTolerance(h, after: 1)
        XCTAssertEqual(h.vm.phase.title, "Пауза")
        XCTAssertEqual(h.log.events.first?.reasonText,
                       "Не удалось определить внешний адрес: таймаут запроса")
        XCTAssertNil(h.log.events.first?.diagnostics?.staleness, "путь пока не менялся")
        let episode = h.log.events.first?.episodeID
        let recordsBefore = h.log.events.count

        // Туннель переподключился: выход другой, а цели те же и стоят.
        h.network.snapshotValue = directSnapshot()
        h.vm.handle(.networkPath)

        XCTAssertEqual(h.vm.phase.title, "Проверка", "у нового пути свой отсчёт")
        XCTAssertEqual(h.log.events.count, recordsBefore, "вторых записей про те же pid нет")
        let refined = h.log.events.filter { $0.episodeID == episode }
        XCTAssertEqual(refined.count, 2, "эпизод тот же, и записи в нём те же")
        XCTAssertEqual(
            Set(refined.map(\.reasonText)),
            ["Подключение ещё не проверено: сменился выход в сеть"],
            "весь эпизод говорит то, что держит цели сейчас"
        )
        let staleness = refined.first?.diagnostics?.staleness
        XCTAssertEqual(staleness?.cause, .networkChanged)
        XCTAssertEqual(staleness?.previousFingerprint, healthySnapshot().verdictFingerprint)
        XCTAssertEqual(staleness?.fingerprint, directSnapshot().verdictFingerprint)

        // Потолок считается от смены пути, и исход дописывается к тем же записям.
        clock.advance(by: Constants.pauseCeilingSeconds + 1)
        h.vm.handle(.tick)

        XCTAssertEqual(h.vm.phase, .danger(.pauseExpired))
        let closed = h.log.events.filter { $0.episodeID == episode }
        XCTAssertEqual(
            Set(closed.map(\.resolutionText)),
            ["завершено по потолку: Подтверждение не получено за 60 с"]
        )
        XCTAssertEqual(
            Set(closed.map(\.reasonText)),
            ["Подключение ещё не проверено: сменился выход в сеть"],
            "исход дописан к причине, которая действительно стояла"
        )
        XCTAssertEqual(closed.first?.diagnostics?.staleness?.cause, .networkChanged,
                       "разбор свежести остаётся при записи и после завершения")
        h.vm.stop()
    }

    /// Цель, умершая под паузой сама, уходит из списка стоящих: отсчёт и кнопка
    /// «Показать терминал» у процесса, которого нет, — обещание, которое интерфейс
    /// не выполнит.
    func test_a_target_that_died_under_the_pause_leaves_the_standing_list() async {
        let locator = MutableLocator(
            bundlePaths: [targetBundleID: targetPath, vpnAppID: vpnAppPath],
            processes: defaultProcesses
        )
        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        settings.isEnabled = true
        settings.vpnAppRule = vpnAppID
        settings.targets = [targetBundleID]

        let vm = GuardVM(
            settings: settings,
            eventLog: EventLogStore(storage: InMemoryEventLog()),
            snapshotReader: StubSnapshotReader(snapshotValue: healthySnapshot()),
            geoProbe: DelayedGeoProbe(),
            locator: locator,
            resolver: StubResolver(mapping: [targetBundleID: targetPath, vpnAppID: vpnAppPath]),
            signaler: SpySignaler(),
            notifier: SpyNotifier(),
            events: ManualEventSource(),
            // Вердикт не должен успеть прийти: проверяется именно стояние.
            debounceInterval: 10
        )

        vm.handle(.networkPath)
        XCTAssertEqual(vm.phase.title, "Проверка")
        XCTAssertTrue(vm.pausedProcesses.contains { $0.pid == 500 }, "цель стоит и видна интерфейсу")

        // Цель ушла сама — под SIGSTOP это делает не она, а тот, кто её послал сигналом,
        // но для weto это просто исчезнувший pid.
        locator.processes = [.init(pid: 700, executablePath: "\(vpnAppPath)/Contents/MacOS/Happ")]
        try? await Task.sleep(for: .seconds(Constants.watchdogIntervalSeconds + 0.15))

        XCTAssertTrue(vm.pausedProcesses.isEmpty, "стоять больше некому")
        XCTAssertEqual(vm.phase.title, "Проверка", "смерть цели фазу не меняет")
        vm.stop()
    }
}
