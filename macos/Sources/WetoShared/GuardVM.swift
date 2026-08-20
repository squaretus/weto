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
    @ObservationIgnored private let snapshotReader: NetworkSnapshotReading
    @ObservationIgnored private let geoProbe: GeoProbing
    @ObservationIgnored private let locator: ProcessLocating
    @ObservationIgnored private let resolver: TargetResolving
    @ObservationIgnored private let killer: ProcessKilling
    @ObservationIgnored private let notifier: KillNotifying
    @ObservationIgnored private let events: NetworkEventSourcing
    @ObservationIgnored private let launchAgent: LaunchAgentManaging

    @ObservationIgnored private var recordedPIDs: Set<Int32> = []

    // Причины, уже описанные в журнале в рамках текущего небезопасного эпизода.
    // Без этого запись «подключение ещё не проверено» съедала бы настоящую причину:
    // pid те же, а дедупликация была только по ним.
    @ObservationIgnored private var recordedReasons: Set<String> = []

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
            onReport: { [weak self] report in self?.receive(report) }
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

            guard settings.targets.contains(bundleID) else { return }

            if case .unsafe(let reason) = state {
                enforce(reason: reason)
                return
            }
        }

        controller.evaluate()
    }

    /// Проверка по кнопке из попапа. Повторное нажатие, пока ответ не пришёл,
    /// не порождает второго запроса: у подтверждающего сервиса есть лимит.
    public func recheckNow() {
        guard !isProbing else { return }
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
            recordedPIDs.removeAll()
            recordedReasons.removeAll()
            state = settings.isEnabled && settings.guardConfig.hasTargets
                ? .safe(lastReading)
                : .disabled

        case .kill(let reason):
            state = .unsafe(reason)
            enforce(reason: reason)
            startWatchdog()
        }
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
        let fresh = matched.filter {
            terminated.contains($0.pid) && (isNewReason || !recordedPIDs.contains($0.pid))
        }
        guard !fresh.isEmpty else { return }

        let kind: KillEventKind = isNewReason ? .terminated : .launchBlocked
        recordedReasons.insert(reasonKey)
        recordedPIDs.formUnion(fresh.map(\.pid))

        var names: [String] = []
        for name in fresh.map(\.targetName) where !names.contains(name) { names.append(name) }

        eventLog.record(KillEvent(
            date: Date(),
            targetNames: names,
            kind: kind,
            reasonText: reason.displayText,
            ip: lastReading?.ip,
            country: lastReading?.primaryCountry,
            confirmedCountry: lastReading?.confirmedCountry,
            confirmSource: lastReading?.confirmSource?.rawValue,
            killedPIDs: fresh.map(\.pid)
        ))
        notifier.notify(
            reasonText: "\(names.joined(separator: ", ")): \(reason.displayText)",
            killedCount: fresh.count
        )
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
