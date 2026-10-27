import Darwin
import Foundation
import WetoCore
import WetoShared
import WetoSystem

/// Лог охраны: строки в stdout с меткой времени. Под launchd stdout — файл
/// `~/Library/Logs/weto.log` (у root — `/Library/Logs/weto.log`), поэтому строка
/// пишется целиком и сразу.
final class GuardLog: @unchecked Sendable {

    private let lock = NSLock()
    private let write: (String) -> Void
    private let now: () -> Date

    init(write: @escaping (String) -> Void = { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
         now: @escaping () -> Date = Date.init) {
        self.write = write
        self.now = now
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()

    func line(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        write("\(Self.formatter.string(from: now())) \(message)")
    }
}

/// Уведомителя рабочего стола у CLI нет: то, что приложение показало бы баннером, —
/// строкой в лог.
///
/// Баннер о завершении приходит без pid, а лог обязан их назвать, поэтому завершение
/// пишет разбор журнала (`GuardRunner.logJournal`) — одной строкой на событие.
/// Здесь остаётся одно: цель, ушедшая в фон под паузой.
struct LogNotifier: GuardNotifying {
    let log: GuardLog

    func notifyTerminated(reasonText: String, killedCount: Int) {}

    func notifyBackgrounded(targetName: String) {
        log.line("\(targetName): процесс вернулся в фон. Откройте терминал и введите fg")
    }
}

/// Автозапуска приложения у CLI нет: свой сервис ставит `weto service install`,
/// а `GuardVM` трогает агент только в `unloadCompletely`, которого CLI не зовёт.
struct DetachedLaunchAgent: LaunchAgentManaging {
    var plistPath: String { "" }
    var isInstalled: Bool { false }
    var pointsAtCurrentBundle: Bool { false }
    func enable() -> Result<Void, LaunchAgentError> { .success(()) }
    func disable() -> Result<Void, LaunchAgentError> { .success(()) }
    func bootout() -> Result<Void, LaunchAgentError> { .success(()) }
}

/// Замок единственного экземпляра — `flock` на `run.lock`. Держится открытым
/// дескриптором до конца процесса: ядро снимает его само, даже при SIGKILL.
struct RunLock {

    enum Outcome: Equatable {
        case acquired(fd: Int32)
        /// Замок занят: pid владельца из файла, если он его успел записать.
        case busy(owner: Int32?)
        case failed(String)
    }

    static func acquire(at url: URL, pid: Int32 = getpid()) -> Outcome {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let fd = open(url.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return .failed(String(cString: strerror(errno))) }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let owner = owner(of: fd)
            close(fd)
            return .busy(owner: owner)
        }
        ftruncate(fd, 0)
        let text = Array("\(pid)\n".utf8)
        _ = text.withUnsafeBufferPointer { pwrite(fd, $0.baseAddress, $0.count, 0) }
        return .acquired(fd: fd)
    }

    private static func owner(of fd: Int32) -> Int32? {
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = buffer.withUnsafeMutableBufferPointer { pread(fd, $0.baseAddress, $0.count, 0) }
        guard count > 0 else { return nil }
        return Int32(String(decoding: buffer.prefix(count), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// `weto run`: охрана на переднем плане. Собирается так же, как у приложения
/// (`AppCoordinator`), — тот же `GuardVM`, — но с хранилищами CLI, файловым токеном,
/// уведомителем-логом и без автозапуска.
@MainActor
final class GuardRunner {

    private let paths: CLIPaths
    private let settings: SettingsStore
    private let appDetector: WetoAppDetecting
    private let log: GuardLog
    private let output: CLIOutput
    /// Проверка релизов; `nil` — версия сборки неизвестна, сравнивать не с чем.
    private let updateSource: UpdateSource?

    private var vm: GuardVM!
    private var updateWatch: UpdateWatch?
    private var updateCheckInFlight = false
    private var eventLog: EventLogStore!
    private var lockDescriptor: Int32 = -1
    private var signalSources: [DispatchSourceSignal] = []
    private var timer: DispatchSourceTimer?
    private var activity: NSObjectProtocol?

    private var lastLoggedPhase: GuardPhase?
    private var seenEvents: Set<UUID> = []
    private var loggedResolutions: Set<UUID> = []
    private var lastStatusWrite = Date.distantPast
    private var lastReload = Date.distantPast
    private var reportedWriteFailure = false

    init(paths: CLIPaths, settings: SettingsStore, appDetector: WetoAppDetecting, log: GuardLog, output: CLIOutput,
         updateSource: UpdateSource?) {
        self.paths = paths
        self.settings = settings
        self.appDetector = appDetector
        self.log = log
        self.output = output
        self.updateSource = updateSource.flatMap { CLIUpdate.knownVersion($0.currentVersion) == nil ? nil : $0 }
    }

    static let appIsRunningText =
        "запущено приложение Weto: две охраны над одними целями мешают друг другу — закройте приложение"
    static let appIsRunningUnderRootText =
        "запущено приложение Weto: две охраны над одними целями мешают друг другу — охрана всей машины продолжает работу, закройте приложение"

    enum AppConflict: Equatable { case none, refuse, warn }

    /// Охрана всей машины из-за найденного приложения не останавливается никогда.
    /// Признак приложения — путь с `/Weto.app/Contents/MacOS/`, а такой бандл любой
    /// пользователь соберёт себе сам: назовёт что угодно `Weto.app`, запустит — и отказ
    /// на старте выключил бы охрану всей машины чужими руками (а `KeepAlive` крутил бы
    /// её перезапуски впустую). Машинная охрана продолжает охранять и предупреждает
    /// в лог. Охране пользователя отказ по-прежнему годится.
    static func appConflict(isSystem: Bool, appIsRunning: Bool) -> AppConflict {
        guard appIsRunning else { return .none }
        return isSystem ? .warn : .refuse
    }

    /// Возвращает код выхода, только если охрана не стартовала. Штатный выход
    /// по сигналу завершает процесс сам, из обработчика.
    func start() -> Int32? {
        switch RunLock.acquire(at: paths.lockFile) {
        case .acquired(let fd):
            lockDescriptor = fd
        case .busy(let owner):
            output.err("охрана уже запущена" + (owner.map { " (pid \($0))" } ?? ""))
            return ExitCode.failure
        case .failed(let detail):
            output.err("не удалось взять замок \(paths.lockFile.path): \(detail)")
            return ExitCode.failure
        }

        switch Self.appConflict(isSystem: paths.isSystem, appIsRunning: appDetector.isWetoAppRunning) {
        case .none:
            break
        case .refuse:
            output.err(Self.appIsRunningText)
            close(lockDescriptor)
            return ExitCode.failure
        case .warn:
            log.line(Self.appIsRunningUnderRootText)
        }

        // App Nap и троттлинг таймеров душат ровно такие процессы: без окон, вся работа —
        // таймеры. Секундный опрос растянулся бы на минуты. Усыплять машину не запрещаем.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "weto: охрана опрашивает процессы и сеть раз в секунду"
        )

        let eventLog = EventLogStore(storage: CLI.journalStorage(paths))
        self.eventLog = eventLog
        seenEvents = Set(eventLog.events.map(\.id))
        loggedResolutions = Set(eventLog.events.filter { $0.resolutionText != nil }.map(\.id))

        vm = GuardVM(
            settings: settings,
            eventLog: eventLog,
            checkLog: CheckLogStore(storage: CLI.checksStorage(paths)),
            snapshotReader: NetworkSnapshotReader(),
            geoProbe: GeoProbe(
                fetcher: URLSessionHTTPFetcher(),
                confirmationFetcher: URLSessionHTTPFetcher(timeout: Constants.geoConfirmationTimeoutSeconds),
                token: { [box = settings.tokenBox] in box.value }
            ),
            locator: ProcessRegistry(),
            signaler: ProcessSignaler(),
            ledger: StoppedLedger(storage: CLI.ledgerStorage(paths)),
            notifier: LogNotifier(log: log),
            // У системной охраны нет GUI-сессии: уведомления `NSWorkspace` ей
            // не положены, цели ловит опрос процессов.
            events: NetworkEventSource(observesWorkspace: !paths.isSystem),
            launchAgent: DetachedLaunchAgent()
        )

        let scope = paths.isSystem ? "вся машина" : "пользователь \(NSUserName())"
        log.line("охрана запущена (pid \(getpid()), \(scope)); \(settingsDescription())")
        if updateSource != nil { updateWatch = UpdateWatch(startedAt: Date()) }
        installSignalHandlers()
        vm.start()
        observe(now: Date())
        startTimer()
        return nil
    }

    private func settingsDescription() -> String {
        let vpn: String
        if let tunnel = settings.vpnTunnel {
            vpn = "туннель \(tunnel)"
        } else if let app = settings.vpnAppRule {
            vpn = "приложение \(app)"
        } else {
            vpn = "не задан"
        }
        let targets = settings.targets.isEmpty ? "нет" : settings.targets.joined(separator: ", ")
        let token = settings.ipinfoToken.isEmpty ? "не задан" : "задан"
        return "VPN: \(vpn); цели: \(targets); \(StatusText.timeoutText(seconds: settings.pauseCeiling.rawValue)); "
            + "токен ipinfo: \(token)"
    }

    // MARK: - Сигналы

    private func installSignalHandlers() {
        for number in [SIGTERM, SIGINT, SIGUSR1] {
            // Обработчик по умолчанию снимается, иначе ядро завершит процесс раньше,
            // чем источник доставит сигнал в очередь.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    if number == SIGUSR1 {
                        self?.checkRequested()
                    } else {
                        self?.shutdown(signal: number)
                    }
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func checkRequested() {
        log.line("проверка подключения по запросу (SIGUSR1)")
        vm.recheckNow()
    }

    /// Штатный выход — тем же кодом, что у приложения: стоящим SIGCONT, исход эпизода
    /// в журнал. Файл статуса удаляется: охраны больше нет.
    private func shutdown(signal number: Int32) {
        log.line("получен \(number == SIGTERM ? "SIGTERM" : "SIGINT") — останавливаю охрану")
        timer?.cancel()
        vm.stop()
        // Только исходы эпизодов: фаза после остановки — «выключено», и строка
        // «цели не выбраны» про остановленную охрану была бы неправдой.
        logJournal()
        try? FileManager.default.removeItem(at: paths.statusFile)
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        log.line("охрана остановлена")
        exit(ExitCode.success)
    }

    // MARK: - Такт CLI

    /// Четверть секунды — чтобы смена фазы попадала в статус и в лог сразу,
    /// а не на следующей секунде. Файл и настройки — раз в секунду.
    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.observe(now: Date()) }
        }
        timer.resume()
        self.timer = timer
    }

    private func observe(now: Date) {
        if now.timeIntervalSince(lastReload) >= 1 {
            lastReload = now
            let ceiling = settings.pauseCeiling
            var changed = settings.reloadFromDefaults().map(Self.fieldName)
            if settings.pauseCeiling != ceiling { changed.append("таймаут") }
            if !changed.isEmpty {
                log.line("настройки изменены (\(changed.joined(separator: ", "))): \(settingsDescription())")
            }
        }

        let phase = vm.phase
        let phaseChanged = phase != lastLoggedPhase
        if phaseChanged {
            lastLoggedPhase = phase
            logPhase(phase, now: now)
        }
        logJournal()
        checkForUpdate(now: now)

        if phaseChanged || now.timeIntervalSince(lastStatusWrite) >= 1 {
            lastStatusWrite = now
            writeStatus(now: now)
        }
    }

    /// Через минуту после старта и раз в сутки — вопрос о релизах. Охрана сама
    /// ничего не ставит: строка в лог и поле в статусе, ставит `sudo weto update`.
    private func checkForUpdate(now: Date) {
        guard let source = updateSource, var watch = updateWatch, !updateCheckInFlight, watch.isDue(at: now) else {
            return
        }
        watch.begin(at: now)
        updateWatch = watch
        updateCheckInFlight = true
        Task { @MainActor [weak self] in
            let result = await source.check()
            guard let self else { return }
            self.updateCheckInFlight = false
            for line in self.updateWatch?.record(result, at: Date()) ?? [] { self.log.line(line) }
        }
    }

    private static func fieldName(_ field: GuardConfigurationChange.Field) -> String {
        switch field {
        case .guardEnabled: return "охрана"
        case .targets: return "цели"
        case .vpnApp: return "VPN-приложение"
        case .vpnTunnel: return "VPN-туннель"
        case .ipinfoToken: return "токен ipinfo"
        case .blacklist: return "чёрный список"
        case .whitelist: return "белый список"
        }
    }

    private func logPhase(_ phase: GuardPhase, now: Date) {
        let explanation = StatusPresentation.explanation(for: phase)
        var line = "фаза: \(phase.title) — \(GuardStatus.actionText(phase.action)): \(explanation.evidence)"
        if case .paused = phase, !vm.pausedProcesses.isEmpty {
            line += "; на паузе: " + vm.pausedProcesses.map { "\($0.targetName) (pid \($0.pid))" }
                .joined(separator: ", ")
        }
        log.line(line)
    }

    /// Новые записи журнала — строкой в лог на событие: эпизод (один проход охраны)
    /// с именами, pid и причиной. Исход эпизода — своей строкой, когда он дописан.
    private func logJournal() {
        let events = Array(eventLog.events.reversed())

        let fresh = events.filter { !seenEvents.contains($0.id) }
        let resolved = events.filter { $0.resolutionText != nil && !loggedResolutions.contains($0.id) }
        for line in Self.journalLogLines(fresh: fresh, resolved: resolved) { log.line(line) }
        seenEvents.formUnion(fresh.map(\.id))
        loggedResolutions.formUnion(resolved.map(\.id))
    }

    /// Строки лога по записям журнала, от старых к новым: событие (эпизод и вид)
    /// — одна строка, исход эпизода — одна строка.
    nonisolated static func journalLogLines(fresh: [KillEvent], resolved: [KillEvent]) -> [String] {
        var lines: [String] = []
        for group in grouped(fresh, by: { "\($0.episodeID)|\($0.kind.rawValue)" }) {
            guard let first = group.first else { continue }
            let verb = first.kind == .paused ? "на паузе" : "завершены"
            lines.append("\(verb): \(names(group)) (pid \(pids(group))) — \(first.reasonText)")
        }
        for group in grouped(resolved, by: { "\($0.episodeID)|\($0.resolutionText ?? "")" }) {
            guard let outcome = group.first?.resolutionText else { continue }
            lines.append("исход паузы: \(outcome) (pid \(pids(group)))")
        }
        return lines
    }

    /// Группы в порядке первого появления: лог читается сверху вниз.
    private nonisolated static func grouped(_ events: [KillEvent], by key: (KillEvent) -> String) -> [[KillEvent]] {
        var order: [String] = []
        var groups: [String: [KillEvent]] = [:]
        for event in events {
            let groupKey = key(event)
            if groups[groupKey] == nil { order.append(groupKey) }
            groups[groupKey, default: []].append(event)
        }
        return order.compactMap { groups[$0] }
    }

    /// «claude ×34, codex» — как в баннере приложения.
    private nonisolated static func names(_ events: [KillEvent]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for event in events {
            if counts[event.targetName] == nil { order.append(event.targetName) }
            counts[event.targetName, default: 0] += 1
        }
        return order.map { counts[$0] == 1 ? $0 : "\($0) ×\(counts[$0] ?? 0)" }.joined(separator: ", ")
    }

    private nonisolated static func pids(_ events: [KillEvent]) -> String {
        events.map { String($0.pid) }.joined(separator: ", ")
    }

    private func writeStatus(now: Date) {
        let status = GuardStatus(GuardStatus.Inputs(
            pid: getpid(),
            now: now,
            phase: vm.phase,
            lastReading: vm.lastReading,
            lastProbeAt: vm.lastReport?.checkedAt,
            pauseDeadline: vm.pauseDeadline,
            outgoing: vm.lastSnapshot?.outgoing,
            vpnAppRule: settings.vpnAppRule,
            vpnAppName: settings.vpnAppRule.map { vm.displayName(forTarget: $0) },
            vpnAppStatus: settings.vpnAppRule == nil ? .notChosen : vm.currentVPNAppStatus(),
            vpnTunnel: settings.vpnTunnel,
            vpnTunnelStatus: vm.currentVPNTunnelStatus(),
            targets: settings.targets.map { (entry: $0, name: vm.displayName(forTarget: $0)) },
            runningTargets: vm.runningTargets,
            pausedProcesses: vm.pausedProcesses,
            pauseCeiling: settings.pauseCeiling,
            updateAvailable: updateWatch?.available
        ))
        do {
            try status.write(to: paths.statusFile)
            if reportedWriteFailure {
                reportedWriteFailure = false
                log.line("файл статуса снова пишется")
            }
        } catch {
            // Раз на серию отказов, а не раз в секунду.
            if !reportedWriteFailure {
                reportedWriteFailure = true
                log.line("не удалось записать \(paths.statusFile.path): \(error.localizedDescription)")
            }
        }
    }
}
