import Foundation
import Observation
import WetoCore
import WetoSystem

public enum GuardStatusColor: Equatable, Sendable {
    case green, yellow, red, grey
}

public enum GuardState: Equatable, Sendable {
    case disabled
    case safe(GeoReading?)
    case unsafe(UnsafeReason)

    public var statusColor: GuardStatusColor {
        switch self {
        case .disabled: return .grey
        case .safe: return .green
        case .unsafe(let reason): return reason.isDegradedRatherThanBlocked ? .yellow : .red
        }
    }

}

@Observable
@MainActor
public final class GuardVM {

    public private(set) var state: GuardState = .disabled
    public private(set) var lastReading: GeoReading?

    /// Что ответил каждый сервис в последней пробе — материал попапа.
    public private(set) var lastReport: GeoProbeReport?

    /// Идёт проверка, запрошенная пользователем.
    public private(set) var isProbing = false

    public private(set) var permissionFailure: String?
    public private(set) var runningTargets: [RunningTarget] = []

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let eventLog: EventLogStore
    @ObservationIgnored private let checkLog: CheckLogStore
    @ObservationIgnored private let snapshotReader: NetworkSnapshotReading
    @ObservationIgnored private let geoProbe: GeoProbing
    @ObservationIgnored private let locator: ProcessLocating
    @ObservationIgnored private let resolver: TargetResolving
    @ObservationIgnored private let killer: ProcessKilling
    @ObservationIgnored private let notifier: KillNotifying
    @ObservationIgnored private let events: NetworkEventSourcing
    @ObservationIgnored private let launchAgent: LaunchAgentManaging

    // Пара «причина + pid»: тот же процесс по той же причине второй записи
    // не заводит, а новый — заводит всегда. Дедупликация только по pid съедала бы
    // настоящую причину, пришедшую на смену «ещё не проверено».
    @ObservationIgnored private var recordedKills: Set<RecordedKill> = []

    // Причины, уже описанные в журнале в рамках текущего небезопасного эпизода.
    @ObservationIgnored private var recordedReasons: Set<String> = []

    // Эпизод, записанный до вердикта: причина в нём — «ещё не проверено»,
    // и её положено уточнить у всех его записей, как только вердикт станет известен.
    @ObservationIgnored private var pendingEpisodeID: UUID?

    // Разбор свежести, с которым эпизод начался. Уточнение причины приходит
    // после пробы, а «что потеряло свежесть» известно только в её начале.
    @ObservationIgnored private var pendingStaleness: VerdictStaleness?

    private struct RecordedKill: Hashable {
        let pid: Int32
        let reason: String
    }

    @ObservationIgnored private var controller: GuardController!
    @ObservationIgnored private var enforcer: ProcessEnforcer!

    // Обход процессов, сделанный для текущего события: синхронное решение
    // обязано убивать по нему же, а не запускать второй обход.
    @ObservationIgnored private var currentScan: ProcessEnforcer.Scan?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var geoTickTask: Task<Void, Never>?
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?

    public init(
        settings: SettingsStore,
        eventLog: EventLogStore,
        checkLog: CheckLogStore = CheckLogStore(storage: InMemoryCheckLog()),
        snapshotReader: NetworkSnapshotReading,
        geoProbe: GeoProbing,
        locator: ProcessLocating,
        resolver: TargetResolving = TargetResolver(),
        killer: ProcessKilling,
        notifier: KillNotifying,
        events: NetworkEventSourcing,
        launchAgent: LaunchAgentManaging = LaunchAgentController(),
        debounceInterval: TimeInterval = Constants.networkEventDebounceSeconds
    ) {
        self.settings = settings
        self.eventLog = eventLog
        self.checkLog = checkLog
        self.snapshotReader = snapshotReader
        self.geoProbe = geoProbe
        self.locator = locator
        self.resolver = resolver
        self.killer = killer
        self.notifier = notifier
        self.events = events
        self.launchAgent = launchAgent

        self.enforcer = ProcessEnforcer(
            settings: settings,
            resolver: resolver,
            locator: locator,
            killer: killer
        )

        self.controller = GuardController(
            settings: settings,
            snapshotReader: snapshotReader,
            geoProbe: geoProbe,
            debounceInterval: debounceInterval,
            vpnAppStatus: { [weak self] in self?.vpnAppStatus() ?? .notChosen },
            onDecision: { [weak self] decision in self?.apply(decision) },
            onReport: { [weak self] report in self?.receive(report) },
            onCheck: { [weak self] check in self?.checkLog.record(check) }
        )

        // Список живых целей обновляется на правку настроек, а не на следующем тике.
        // Вердикт контроллер пересчитывает сам, но пользователь смотрит на другое:
        // добавил цель — и до тика в интерфейсе не менялось ничего, отчего казалось,
        // что цель подхватится только после перезапуска приложения.
        settings.onGuardConfigurationChange { [weak self] change in
            guard change.field == .targets || change.field == .vpnApp else { return }
            self?.refreshRunningTargets()
        }
    }

    deinit {
        tickTask?.cancel()
        geoTickTask?.cancel()
        watchdogTask?.cancel()
    }

    public func start() {
        refreshRunningTargets()
        events.start { [weak self] trigger in
            Task { @MainActor [weak self] in self?.handle(trigger) }
        }
        startTicking()
        startGeoTicking()
        handle(.tick)
    }

    public func stop() {
        events.stop()
        controller.stop()
        tickTask?.cancel(); tickTask = nil
        geoTickTask?.cancel(); geoTickTask = nil
        watchdogTask?.cancel(); watchdogTask = nil
    }

    /// Цвет статуса для глаза.
    ///
    /// Отдельно от `state.statusColor`: «на страже, но ipinfo молчит» для целей —
    /// по-прежнему safe, потому что адрес доказанно тот же, а для пользователя это
    /// не полноценная зелёная защита. Зелёный тут врал бы.
    public var statusColor: GuardStatusColor {
        guard case .safe(let reading) = state, reading != nil,
              let report = lastReport, case .failed = report.ipinfo
        else { return state.statusColor }
        return .yellow
    }

    public var currentCountryCode: String? {
        switch state {
        case .disabled:
            return nil
        case .safe(let reading):
            return reading?.primaryCountry
        case .unsafe(let reason):
            switch reason {
            case .vpnAppNotChosen, .vpnAppNotRunning, .geoUnavailable:
                return nil
            default:
                return lastReading?.primaryCountry
            }
        }
    }

    @discardableResult
    public func unloadCompletely() -> Result<Void, LaunchAgentError> {
        stop()
        return launchAgent.disable()
    }

    /// Запущено ли выбранное VPN-приложение.
    ///
    /// Считается по уже снятому скану: обход процессов идёт раз в тик и один,
    /// а правило приложения разрешается тем же путём, что цели, — с симлинками,
    /// версионными путями и скриптами по argv.
    private func vpnAppStatus() -> VPNAppStatus {
        guard settings.vpnAppRule != nil else { return .notChosen }
        guard let rule = enforcer.vpnAppRule() else { return .notRunning }

        let scan = currentScan ?? enforcer.scan(includingVPNApp: true)
        return ProcessMatcher.pids(in: scan.processes, rules: [rule]).isEmpty
            ? .notRunning
            : .running
    }

    public func refreshRunningTargets() {
        runningTargets = enforcer.runningTargets(in: enforcer.scan())
    }

    /// Считается по уже собранному списку: строка настроек не имеет права
    /// запускать собственный обход процессов на каждую цель.
    public func runningProcessCount(forTarget entry: String) -> Int {
        runningTargets
            .filter { $0.entry == entry }
            .reduce(0) { $0 + $1.processCount }
    }

    public func resolvedDescription(forTarget entry: String) -> String {
        guard let rule = resolver.resolve(entry) else { return "не найдено в системе" }
        switch rule.kind {
        case .appBundle: return "приложение: \(rule.path)"
        case .binary: return "бинарник: \(rule.path)"
        case .script: return "скрипт: \(rule.path)"
        }
    }

    public func displayName(forTarget entry: String) -> String {
        resolver.resolve(entry)?.displayName ?? entry
    }

    public func handle(_ trigger: GuardTrigger) {
        let scan = enforcer.scan(includingVPNApp: true)
        currentScan = scan
        defer { currentScan = nil }

        runningTargets = enforcer.runningTargets(in: scan)

        // Расписание гео — единственный триггер, который сам идёт в сеть.
        if case .geoSchedule = trigger {
            controller.probeOnSchedule()
            return
        }

        if case .appLaunched(let bundleID) = trigger {

            // VPN-приложение целью не бывает: его выбор снимает его из целей.
            // Но его запуск — то самое событие, ради которого вердикт и пересчитывают,
            // и раньше проверка «это цель?» отправляла его в никуда. Закрытие клиента
            // при этом обрабатывалось, то есть охрана замечала уход защиты сразу,
            // а её возвращение — только следующим тактом.
            let isVPNApp = settings.vpnAppRule == bundleID
            guard isVPNApp || settings.targets.contains(bundleID) else { return }

            if !isVPNApp, case .unsafe(let reason) = state {
                enforce(reason: reason)
                return
            }
        }

        controller.evaluate()
    }

    /// Проверка по кнопке из попапа. Повторное нажатие, пока ответ не пришёл,
    /// не порождает второго запроса: у подтверждающего сервиса есть лимит.
    public func recheckNow() {
        guard !isProbing else {
            // Нажатие, отбитое индикатором, тоже событие: без записи «нажал пять
            // раз, а запрос не ушёл» не отличить от «кнопка не работает».
            checkLog.record(CheckEvent(
                date: Date(),
                trigger: .manual,
                outcome: .skippedProbeInFlight,
                fingerprint: snapshotReader.snapshot().verdictFingerprint
            ))
            return
        }
        isProbing = true
        controller.probeNow()

        Task { [weak self] in
            await self?.awaitPendingProbe()
            self?.isProbing = false
        }
    }

    public func awaitPendingProbe() async {
        await controller.awaitPendingProbe()
    }

    private func receive(_ report: GeoProbeReport?) {
        lastReport = report
        guard let report else {
            // Гасим и запасное чтение: попап падает на него, когда отчёта нет,
            // и без этого на экране осталась бы всё та же чужая страна.
            lastReading = nil
            return
        }
        guard case .resolved(let reading) = report.outcome else { return }
        lastReading = reading
    }

    private func apply(_ decision: GuardDecision) {
        switch decision {
        case .safe:
            watchdogTask?.cancel(); watchdogTask = nil
            permissionFailure = nil
            resolvePendingEpisodeAsSafe()
            recordedKills.removeAll()
            recordedReasons.removeAll()
            state = settings.isEnabled && settings.guardConfig.hasTargets
                ? .safe(lastReading)
                : .disabled

        case .kill(let reason):
            state = .unsafe(reason)
            refineEpisodeReason(to: reason)
            enforce(reason: reason)
            startWatchdog()
        }
    }

    /// Причина эпизода, ставшая известной, дописывается всем его записям.
    ///
    /// Ключ причины в `recordedReasons` подменяется вместе с текстом: иначе
    /// уточнённая причина считалась бы новой и завела бы второй набор записей
    /// про то же самое падение.
    private func refineEpisodeReason(to reason: UnsafeReason) {
        if case .verificationPending = reason { return }
        guard let episodeID = pendingEpisodeID else { return }

        pendingEpisodeID = nil
        let pending = UnsafeReason.verificationPending.displayText
        recordedReasons.remove(pending)
        recordedReasons.insert(reason.displayText)

        // Ключ дедупликации переезжает вместе с текстом: те же процессы того же
        // эпизода под уточнённой причиной выглядели бы новыми и завели бы второй
        // набор записей про то же самое падение.
        recordedKills = Set(recordedKills.map {
            $0.reason == pending ? RecordedKill(pid: $0.pid, reason: reason.displayText) : $0
        })

        // Диагностика дописывается вместе с причиной: эпизод начался до пробы,
        // и в момент записи трасс ещё не существовало.
        eventLog.refine(
            episodeID: episodeID,
            reasonText: reason.displayText,
            ip: lastReading?.ip,
            country: lastReading?.primaryCountry,
            confirmedCountry: lastReading?.confirmedCountry,
            confirmSource: lastReading?.confirmSource?.rawValue,
            diagnostics: currentDiagnostics(for: reason, staleness: pendingStaleness)
        )
    }

    /// Эпизод, начавшийся до вердикта, закончился безопасным выходом.
    ///
    /// Это и есть случай, который выглядит как «weto завершает процессы случайно»:
    /// вердикт потерял свежесть, fail-closed завершил цели, а через секунду проверка
    /// сказала «всё в порядке». Уточнять причину нечем — она и была «ещё не проверено», —
    /// но запись обязана сказать, чем дело кончилось, иначе в журнале навсегда
    /// остаётся отговорка без единой цифры.
    private func resolvePendingEpisodeAsSafe() {
        guard let episodeID = pendingEpisodeID else { return }
        pendingEpisodeID = nil

        let outcome: String
        if let reading = lastReading {
            outcome = "проверка завершилась безопасным выходом: \(reading.ip), \(reading.primaryCountry)"
        } else {
            outcome = "проверка завершилась безопасным выходом"
        }

        eventLog.refine(
            episodeID: episodeID,
            reasonText: UnsafeReason.verificationPending.displayText,
            resolutionText: outcome,
            ip: lastReading?.ip,
            country: lastReading?.primaryCountry,
            confirmedCountry: lastReading?.confirmedCountry,
            confirmSource: lastReading?.confirmSource?.rawValue,
            diagnostics: currentDiagnostics(
                for: .verificationPending, staleness: pendingStaleness
            )
        )
    }

    private func enforce(reason: UnsafeReason) {
        let outcome = enforcer.enforce(currentScan ?? enforcer.scan())
        let matched = outcome.matched
        guard !matched.isEmpty else { return }

        let results = outcome.results
        let refused = results.filter { !$0.isTerminated }
        permissionFailure = refused.isEmpty
            ? nil
            : "Не удалось завершить процессы \(refused.map(\.pid)) — недостаточно прав"

        let terminated = Set(results.filter(\.isTerminated).map(\.pid))
        let reasonKey = reason.displayText
        let isNewReason = !recordedReasons.contains(reasonKey)

        // Дедупликация по паре «причина + pid»: тот же процесс по той же причине
        // второй записи не заводит, а запущенный заново — заводит всегда.
        let fresh = matched.filter {
            terminated.contains($0.pid)
                && !recordedKills.contains(RecordedKill(pid: $0.pid, reason: reasonKey))
        }
        guard !fresh.isEmpty else { return }

        let kind: KillEventKind = isNewReason ? .terminated : .launchBlocked
        recordedReasons.insert(reasonKey)
        recordedKills.formUnion(fresh.map { RecordedKill(pid: $0.pid, reason: reasonKey) })

        // Один проход охраны — один эпизод: сколько процессов завершено,
        // столько и записей, и все они помнят, что это было одно событие.
        let episodeID = UUID()
        let moment = Date()
        let diagnostics = currentDiagnostics(for: reason)
        let batch = fresh.map { process in
            KillEvent(
                episodeID: episodeID,
                date: moment,
                targetName: process.targetName,
                pid: process.pid,
                parentPID: process.parentPID,
                executablePath: process.executablePath,
                isDescendant: process.isDescendant,
                kind: kind,
                reasonText: reason.displayText,
                ip: lastReading?.ip,
                country: lastReading?.primaryCountry,
                confirmedCountry: lastReading?.confirmedCountry,
                confirmSource: lastReading?.confirmSource?.rawValue,
                diagnostics: diagnostics
            )
        }
        eventLog.record(batch)
        if case .verificationPending = reason {
            pendingEpisodeID = episodeID
            pendingStaleness = diagnostics.staleness
        }

        // Уведомление — на проход, а не на процесс: тридцать четыре баннера подряд
        // не сообщение, а помеха. Цели в нём перечислены с числом завершённого,
        // потому что «claude» и «claude ×34» — разные новости.
        notifier.notify(reasonText: "\(Self.targetsSummary(of: fresh)): \(reason.displayText)",
                        killedCount: fresh.count)
    }

    /// Отладочные показания эпизода: они не показываются пользователю и нужны
    /// только выгрузке. Причина «подключение ещё не проверено» без них неотличима
    /// от «изменили настройки», и завершение выглядит беспричинным.
    private func currentDiagnostics(
        for reason: UnsafeReason,
        staleness explicit: VerdictStaleness? = nil
    ) -> KillDiagnostics {
        let snapshot = controller.lastSnapshot
        let staleness: VerdictStaleness?
        if let explicit {
            staleness = explicit
        } else if case .verificationPending = reason {
            staleness = controller.lastStaleness
        } else {
            staleness = nil
        }

        return KillDiagnostics(
            staleness: staleness,
            outgoingInterface: snapshot?.outgoing?.interface,
            outgoingAddress: snapshot?.outgoing?.address,
            hasNetworkPath: lastReport?.hasNetworkPath,
            vpnAppEntry: settings.vpnAppRule,
            vpnAppStatus: String(describing: vpnAppStatus()),
            services: lastReport?.traces ?? [],
            probedAt: lastReport?.checkedAt,
            appVersion: Constants.appVersion
        )
    }

    /// «claude ×34, codex» — цели прохода с числом завершённых процессов там,
    /// где их больше одного.
    private static func targetsSummary(of processes: [MatchedProcess]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for process in processes {
            if counts[process.targetName] == nil { order.append(process.targetName) }
            counts[process.targetName, default: 0] += 1
        }
        return order
            .map { name in counts[name] == 1 ? name : "\(name) ×\(counts[name] ?? 0)" }
            .joined(separator: ", ")
    }

    private func startWatchdog() {
        guard watchdogTask == nil else { return }
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Constants.watchdogIntervalSeconds))
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, case .unsafe(let reason) = self.state else { return }
                    self.enforce(reason: reason)
                }
            }
        }
    }

    /// Расписание обращений к гео-сервисам. Свой таймер, а не общий тик: опрос системы
    /// частый и бесплатный, запрос к чужим сервисам редкий и платный.
    private func startGeoTicking() {
        geoTickTask?.cancel()
        geoTickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Constants.geoProbeIntervalSeconds))
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in self?.handle(.geoSchedule) }
            }
        }
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Constants.tickIntervalSeconds))
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in self?.handle(.tick) }
            }
        }
    }
}
