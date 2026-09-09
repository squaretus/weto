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

private final class SilentSignaler: ProcessSignaling, @unchecked Sendable {
    func send(_ signal: ProcessSignal, to pids: [Int32]) -> [SignalResult] {
        pids.map { SignalResult(pid: $0, errorCode: nil) }
    }
}

/// Записывающий двойник: фиксирует порядок и содержимое каждой партии сигналов,
/// а не только итоговый результат — контракт порядка иначе доказать нельзя.
private final class RecordingSignaler: ProcessSignaling, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(signal: ProcessSignal, pids: [Int32])] = []
    var refused: Set<Int32> = []

    var batches: [(signal: ProcessSignal, pids: [Int32])] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func send(_ signal: ProcessSignal, to pids: [Int32]) -> [SignalResult] {
        lock.lock(); stored.append((signal, pids)); let refused = self.refused; lock.unlock()
        return pids.map { SignalResult(pid: $0, errorCode: refused.contains($0) ? EPERM : nil) }
    }
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
        clock: TestClock,
        signaler: ProcessSignaling = SilentSignaler(),
        ledger: StoppedLedger? = nil
    ) -> ProcessEnforcer {
        let ledger = ledger ?? StoppedLedger(storage: InMemoryStoppedLedger())
        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        settings.targets = targets
        return ProcessEnforcer(
            settings: settings,
            resolver: resolver,
            locator: locator,
            signaler: signaler,
            ledger: ledger,
            now: { clock.now }
        )
    }

    // Дерево переднего задания из PausePlannerTests: интерактивный шелл, его цель
    // и потомок цели — ровно тот случай, где порядок сигналов доказывает контракт.
    private let shell = ProcessSnapshot(pid: 100, parentPID: 1, executablePath: "/bin/zsh",
                                        processGroup: 100, terminalForegroundGroup: 200)
    private let target = ProcessSnapshot(pid: 200, parentPID: 100, executablePath: "/Users/me/.local/share/claude/versions/2.1.227",
                                         processGroup: 200, terminalForegroundGroup: 200)
    private let child = ProcessSnapshot(pid: 201, parentPID: 200, executablePath: "/usr/bin/node",
                                        processGroup: 200, terminalForegroundGroup: 200)

    /// Тот же процесс, каким его показывает ядро после SIGSTOP: `SSTOP`.
    private static func stopped(_ process: ProcessSnapshot) -> ProcessSnapshot {
        ProcessSnapshot(pid: process.pid, parentPID: process.parentPID,
                        executablePath: process.executablePath, arguments: process.arguments,
                        processGroup: process.processGroup,
                        terminalForegroundGroup: process.terminalForegroundGroup, isStopped: true)
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
            enforcer.terminate(enforcer.scan()).matched.map(\.pid),
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
            enforcer.terminate(enforcer.scan()).matched.map(\.pid),
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

    func test_pause_stops_shell_then_target_then_child_and_records_them() {
        let signaler = RecordingSignaler(); let ledger = StoppedLedger(storage: InMemoryStoppedLedger())
        let enforcer = makeEnforcer(targets: [entry], resolver: MutableResolver([entry: oldVersionPath]),
                                    locator: MutableProcessLocator([shell, target, child]), clock: TestClock(),
                                    signaler: signaler, ledger: ledger)

        let outcome = enforcer.pause(enforcer.scan())

        XCTAssertEqual(signaler.batches.map(\.signal), [.stop])
        XCTAssertEqual(signaler.batches.first?.pids, [100, 200, 201])
        XCTAssertEqual(outcome.fresh.map(\.pid), [200, 201], "шелл — не цель и в журнал не идёт")
        XCTAssertEqual(ledger.pids, [100, 200, 201])
        XCTAssertEqual(ledger.entries.first?.isShell, true)
    }

    /// Учёт хранит путь бинарника ровно затем, что pid ядро переиспользует: запись
    /// об уже мёртвом владельце этого числа не имеет права сойти за «мы её уже остановили»
    /// и молча выпустить свежую цель, которой достался тот же pid, из-под паузы.
    func test_pause_stops_a_target_whose_pid_was_recycled_from_a_stale_ledger_entry() {
        let signaler = RecordingSignaler()
        let ledgerStorage = InMemoryStoppedLedger()
        ledgerStorage.save([
            StoppedProcess(pid: target.pid, executablePath: "/usr/bin/some-other-dead-process",
                           stoppedAt: Date(), isShell: false),
        ])
        let enforcer = makeEnforcer(targets: [entry], resolver: MutableResolver([entry: oldVersionPath]),
                                    locator: MutableProcessLocator([shell, target, child]), clock: TestClock(),
                                    signaler: signaler, ledger: StoppedLedger(storage: ledgerStorage))

        let outcome = enforcer.pause(enforcer.scan())

        XCTAssertEqual(signaler.batches.map(\.signal), [.stop])
        XCTAssertEqual(signaler.batches.first?.pids, [100, 200, 201],
                       "pid цели переиспользован не нашим процессом — цель обязана быть остановлена")
        XCTAssertEqual(outcome.fresh.map(\.pid), [200, 201])
        XCTAssertEqual(Set(ledgerStorage.load().entries.map(\.pid)), [100, 200, 201])
    }

    /// Второй обход под паузой не шлёт SIGSTOP уже стоящим — только новорождённым.
    ///
    /// «Уже стоит по нашей вине» спрашивается у ядра, а не у одного учёта: с тех пор
    /// как учёт держит обязательство до наблюдения, в нём остаётся и запись, до которой
    /// SIGCONT уже дошёл. Поэтому снимок между проходами обязан быть настоящим —
    /// остановленные показаны остановленными.
    func test_a_second_sweep_stops_only_newcomers() {
        let signaler = RecordingSignaler(); let ledger = StoppedLedger(storage: InMemoryStoppedLedger())
        let locator = MutableProcessLocator([shell, target])
        let enforcer = makeEnforcer(targets: [entry], resolver: MutableResolver([entry: oldVersionPath]),
                                    locator: locator, clock: TestClock(), signaler: signaler, ledger: ledger)
        _ = enforcer.pause(enforcer.scan())

        locator.replace(with: [Self.stopped(shell), Self.stopped(target), child])
        let second = enforcer.pause(enforcer.scan())

        XCTAssertEqual(signaler.batches.last?.pids, [201])
        XCTAssertEqual(second.fresh.map(\.pid), [201])
    }

    /// Запись, которую SIGCONT уже разбудил, а наблюдения ещё не было, остаётся в учёте.
    /// Ожившая цель обязана снова получить SIGSTOP — иначе «мы её уже остановили»
    /// молча выпускало бы работающий процесс из-под паузы, — но второй записи в журнал
    /// она не заводит: про этот pid эпизод уже рассказал.
    func test_pause_stops_a_ledger_entry_that_is_running_again_without_recording_it_twice() {
        let signaler = RecordingSignaler(); let ledger = StoppedLedger(storage: InMemoryStoppedLedger())
        let locator = MutableProcessLocator([shell, target, child])
        let enforcer = makeEnforcer(targets: [entry], resolver: MutableResolver([entry: oldVersionPath]),
                                    locator: locator, clock: TestClock(), signaler: signaler, ledger: ledger)
        let first = enforcer.pause(enforcer.scan())
        XCTAssertEqual(first.fresh.map(\.pid), [200, 201])

        // Учёт держит их до наблюдения, а ядро показывает идущими: SIGCONT дошёл.
        let second = enforcer.pause(enforcer.scan())

        XCTAssertEqual(signaler.batches.map(\.signal), [.stop, .stop])
        XCTAssertEqual(signaler.batches.last?.pids, [100, 200, 201], "идущая цель встаёт заново")
        XCTAssertTrue(second.fresh.isEmpty, "повторной записи о том же pid журнал не допускает")
        XCTAssertEqual(ledger.pids, [100, 200, 201])
    }

    func test_resume_walks_the_ledger_backwards_and_clears_it() {
        let signaler = RecordingSignaler(); let ledger = StoppedLedger(storage: InMemoryStoppedLedger())
        let enforcer = makeEnforcer(targets: [entry], resolver: MutableResolver([entry: oldVersionPath]),
                                    locator: MutableProcessLocator([shell, target, child]), clock: TestClock(),
                                    signaler: signaler, ledger: ledger)
        _ = enforcer.pause(enforcer.scan())

        _ = enforcer.resume()

        XCTAssertEqual(signaler.batches.last?.signal, .resume)
        XCTAssertEqual(signaler.batches.last?.pids, [201, 200, 100], "цель раньше шелла")
        XCTAssertTrue(ledger.pids.isEmpty)
    }

    /// Завершение стоящих целей: SIGKILL целям, SIGCONT шеллу — иначе терминал остаётся мёртвым.
    func test_terminate_kills_targets_and_releases_their_shell() {
        let signaler = RecordingSignaler(); let ledger = StoppedLedger(storage: InMemoryStoppedLedger())
        let enforcer = makeEnforcer(targets: [entry], resolver: MutableResolver([entry: oldVersionPath]),
                                    locator: MutableProcessLocator([shell, target, child]), clock: TestClock(),
                                    signaler: signaler, ledger: ledger)
        _ = enforcer.pause(enforcer.scan())

        let result = enforcer.terminate(enforcer.scan())

        XCTAssertEqual(Set(result.matched.map(\.pid)), [200, 201])
        XCTAssertEqual(signaler.batches.map(\.signal), [.stop, .kill, .resume])
        XCTAssertEqual(signaler.batches.last?.pids, [100])
        XCTAssertTrue(ledger.pids.isEmpty)
    }

    /// Запись в учёте перестаёт совпадать ни с одним правилом между паузой и завершением —
    /// вторую цель сняли с охраны (чекбокс в настройках), пока её процесс стоял. Раньше
    /// `terminate` продолжал только шеллы: такая запись осталась бы замороженной до
    /// следующего запуска weto. Критерий приёмки — «Пауза» → «Опасно» никого не оставляет
    /// замороженным: SIGCONT обязан дойти до любой записи, не попавшей под SIGKILL.
    func test_terminate_resumes_a_ledger_entry_that_stopped_matching_any_rule() {
        let otherEntry = "/Users/me/.local/bin/other"
        let otherPath = "/usr/local/bin/other-tool"
        let other = ProcessSnapshot(pid: 400, parentPID: 1, executablePath: otherPath)

        let signaler = RecordingSignaler(); let ledger = StoppedLedger(storage: InMemoryStoppedLedger())
        let clock = TestClock()
        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        settings.targets = [entry, otherEntry]
        let enforcer = ProcessEnforcer(
            settings: settings,
            resolver: MutableResolver([entry: oldVersionPath, otherEntry: otherPath]),
            locator: MutableProcessLocator([shell, target, child, other]),
            signaler: signaler,
            ledger: ledger,
            now: { clock.now }
        )
        _ = enforcer.pause(enforcer.scan())
        XCTAssertEqual(ledger.pids, [100, 400, 200, 201], "вторая цель встала под паузу вместе с первой")

        settings.targets = [entry] // вторую цель сняли с охраны, пока она стояла

        let result = enforcer.terminate(enforcer.scan())

        XCTAssertEqual(result.matched.map(\.pid), [200, 201], "снятая цель под правило уже не попадает")
        XCTAssertEqual(signaler.batches.map(\.signal), [.stop, .kill, .resume])
        XCTAssertEqual(signaler.batches[1].pids, [200, 201], "SIGKILL — только тем, кто всё ещё под правилом")
        XCTAssertEqual(signaler.batches[2].pids, [400, 100],
                       "SIGCONT — и шеллу, и записи, переставшей совпадать с правилом")
        XCTAssertTrue(ledger.pids.isEmpty)
    }

    /// Цель, которую не удалось завершить (EPERM), остаётся в учёте: штатный выход её продолжит.
    func test_a_refused_kill_keeps_the_process_in_the_ledger() {
        let signaler = RecordingSignaler(); signaler.refused = [201]
        let ledger = StoppedLedger(storage: InMemoryStoppedLedger())
        let enforcer = makeEnforcer(targets: [entry], resolver: MutableResolver([entry: oldVersionPath]),
                                    locator: MutableProcessLocator([shell, target, child]), clock: TestClock(),
                                    signaler: signaler, ledger: ledger)
        signaler.refused = []
        _ = enforcer.pause(enforcer.scan())
        signaler.refused = [201]

        _ = enforcer.terminate(enforcer.scan())

        XCTAssertEqual(ledger.pids, [201])
    }

    /// После падения: SIGCONT тем, кто стоит и остался тем же процессом; чужой pid не трогаем.
    func test_orphans_are_resumed_only_when_still_stopped_and_the_same_executable() {
        let ledgerStorage = InMemoryStoppedLedger()
        ledgerStorage.save([
            StoppedProcess(pid: 200, executablePath: target.executablePath, stoppedAt: Date(), isShell: false),
            StoppedProcess(pid: 201, executablePath: "/usr/bin/node", stoppedAt: Date(), isShell: false),
            StoppedProcess(pid: 100, executablePath: "/bin/zsh", stoppedAt: Date(), isShell: true),
        ])
        let signaler = RecordingSignaler()
        let alive = [
            ProcessSnapshot(pid: 100, parentPID: 1, executablePath: "/bin/zsh", isStopped: true),
            ProcessSnapshot(pid: 200, parentPID: 100, executablePath: target.executablePath, isStopped: true),
            ProcessSnapshot(pid: 201, parentPID: 1, executablePath: "/usr/bin/python3", isStopped: true), // pid переиспользован
        ]
        let enforcer = makeEnforcer(targets: [entry], resolver: MutableResolver([entry: oldVersionPath]),
                                    locator: MutableProcessLocator(alive), clock: TestClock(),
                                    signaler: signaler, ledger: StoppedLedger(storage: ledgerStorage))

        enforcer.resumeOrphans()

        XCTAssertEqual(signaler.batches.first?.signal, .resume)
        XCTAssertEqual(signaler.batches.first?.pids, [200, 100], "цель раньше шелла, чужой pid пропущен")
        XCTAssertEqual(ledgerStorage.load().entries.map(\.pid), [200, 100],
                       "обязательство снимает наблюдение: запись, которую этот проход "
                        + "не увидел идущей, из учёта не уходит")
    }

    /// Тест выше сеет учёт вручную в порядке «цель, потомок, шелл» — так `pause()` его
    /// никогда не напишет (шелл там всегда идёт первым). Этот тест строит учёт настоящим
    /// `pause()`, затем поднимает НАД ТЕМ ЖЕ ФАЙЛОМ свежий `ProcessEnforcer` — ровно так,
    /// как выглядел бы перезапуск после падения, — и проверяет порядок, который
    /// `resumeOrphans` даёт из подлинной записи, а не из порядка, придуманного тестом.
    func test_resumeOrphans_round_trips_through_a_ledger_written_by_a_real_pause() {
        let ledgerStorage = InMemoryStoppedLedger()
        let firstEnforcer = makeEnforcer(targets: [entry], resolver: MutableResolver([entry: oldVersionPath]),
                                         locator: MutableProcessLocator([shell, target, child]), clock: TestClock(),
                                         signaler: RecordingSignaler(), ledger: StoppedLedger(storage: ledgerStorage))
        _ = firstEnforcer.pause(firstEnforcer.scan())
        // Настоящий pause() пишет в файл [шелл, цель, потомок] — PausePlanner ставит
        // шеллы первыми (см. PausePlan.swift): stopOrder = shells + ordered.
        XCTAssertEqual(ledgerStorage.load().entries.map(\.pid), [100, 200, 201])

        // «Падение и перезапуск weto»: те же три процесса всё ещё стоят (SSTOP),
        // но обслуживает их уже другой ProcessEnforcer над тем же файлом на диске.
        let stoppedShell = ProcessSnapshot(pid: shell.pid, parentPID: shell.parentPID,
                                           executablePath: shell.executablePath, processGroup: shell.processGroup,
                                           terminalForegroundGroup: shell.terminalForegroundGroup, isStopped: true)
        let stoppedTarget = ProcessSnapshot(pid: target.pid, parentPID: target.parentPID,
                                            executablePath: target.executablePath, processGroup: target.processGroup,
                                            terminalForegroundGroup: target.terminalForegroundGroup, isStopped: true)
        let stoppedChild = ProcessSnapshot(pid: child.pid, parentPID: child.parentPID,
                                           executablePath: child.executablePath, processGroup: child.processGroup,
                                           terminalForegroundGroup: child.terminalForegroundGroup, isStopped: true)
        let secondSignaler = RecordingSignaler()
        let secondEnforcer = makeEnforcer(targets: [entry], resolver: MutableResolver([entry: oldVersionPath]),
                                          locator: MutableProcessLocator([stoppedShell, stoppedTarget, stoppedChild]),
                                          clock: TestClock(), signaler: secondSignaler,
                                          ledger: StoppedLedger(storage: ledgerStorage))

        secondEnforcer.resumeOrphans()

        // Учёт на диске несёт только `isShell`, не глубину дерева: «потомок раньше цели»
        // из настоящего стоп-порядка восстановить нечем. Ближайшее и уже принятое на
        // ревью приближение — все не-шеллы раньше шеллов, порядок внутри группы как
        // в файле, а файл писала pause() в порядке [шелл, цель, потомок]. После вычитания
        // шелла из не-шелльной группы остаётся [цель, потомок], затем шелл.
        XCTAssertEqual(secondSignaler.batches.first?.signal, .resume)
        XCTAssertEqual(secondSignaler.batches.first?.pids, [200, 201, 100],
                       "обе цели продолжены раньше шелла; порядок внутри группы — как записал pause()")
        XCTAssertEqual(ledgerStorage.load().entries.map(\.pid), [100, 200, 201],
                       "все трое всё ещё стоят: до наблюдения обязательство держится")
    }

    /// Учёт после падения не вычёркивается отправкой сигнала: пока ядро показывает
    /// процесс стоящим, запись живёт и получает SIGCONT снова. Иначе цель, вернувшаяся
    /// в стоп по SIGTTIN, оставалась бы замороженной навсегда — досылать ей сигнал
    /// было бы уже некому.
    func test_orphan_that_stays_stopped_keeps_its_entry_and_is_signalled_again() {
        let ledgerStorage = InMemoryStoppedLedger()
        ledgerStorage.save([
            StoppedProcess(pid: 200, executablePath: target.executablePath, stoppedAt: Date(), isShell: false),
        ])
        let signaler = RecordingSignaler()
        let locator = MutableProcessLocator([Self.stopped(target)])
        let enforcer = makeEnforcer(targets: [entry], resolver: MutableResolver([entry: oldVersionPath]),
                                    locator: locator, clock: TestClock(),
                                    signaler: signaler, ledger: StoppedLedger(storage: ledgerStorage))

        enforcer.resumeOrphans()
        let second = enforcer.resume(observing: nil)

        XCTAssertEqual(signaler.batches.map(\.signal), [.resume, .resume])
        XCTAssertEqual(signaler.batches.last?.pids, [200], "следующий проход шлёт SIGCONT снова")
        XCTAssertEqual(second.unresolved.map(\.pid), [200])
        XCTAssertTrue(second.released.isEmpty)
        XCTAssertEqual(ledgerStorage.load().entries.map(\.pid), [200])

        // Пользователь ввёл `fg` — процесс пошёл, и вот теперь обязательство снято.
        locator.replace(with: [target])
        let third = enforcer.resume(observing: nil)

        XCTAssertEqual(third.released, [200])
        XCTAssertTrue(third.unresolved.isEmpty)
        XCTAssertEqual(ledgerStorage.load(), .entries([]))
    }
}
