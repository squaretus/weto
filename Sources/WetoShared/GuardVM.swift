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

    public private(set) var permissionFailure: String?
    public private(set) var availableVPNs: [NetworkServiceSnapshot] = []
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
            onDecision: { [weak self] decision in self?.apply(decision) },
            onReading: { [weak self] reading in self?.receive(reading) }
        )
    }

    deinit {
        tickTask?.cancel()
        watchdogTask?.cancel()
    }

    public func start() {
        // Миграция выбора «по имени» на UUID выполняется до первого решения:
        // иначе прежний выбор выглядел бы как «VPN не выбран» и цели ушли бы зря.
        settings.migrateLegacyVPNSelection(in: snapshotReader.snapshot())
        refreshVPNCandidates()
        refreshRunningTargets()
        events.start { [weak self] trigger in
            Task { @MainActor [weak self] in self?.handle(trigger) }
        }
        startTicking()
        handle(.tick)
    }

    public func stop() {
        events.stop()
        controller.stop()
        tickTask?.cancel(); tickTask = nil
        watchdogTask?.cancel(); watchdogTask = nil
    }

    public var currentCountryCode: String? {
        switch state {
        case .disabled:
            return nil
        case .safe(let reading):
            return reading?.primaryCountry
        case .unsafe(let reason):
            switch reason {
            case .vpnNotConfigured, .vpnDown, .vpnNotPrimary, .geoUnavailable:
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

    public func refreshVPNCandidates() {
        availableVPNs = snapshotReader.snapshot().vpnCandidates
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
        let scan = enforcer.scan()
        currentScan = scan
        defer { currentScan = nil }

        runningTargets = enforcer.runningTargets(in: scan)

        if case .appLaunched(let bundleID) = trigger {

            guard settings.targets.contains(bundleID) else { return }

            if case .unsafe(let reason) = state {
                enforce(reason: reason)
                return
            }
        }

        controller.evaluate()
    }

    public func awaitPendingProbe() async {
        await controller.awaitPendingProbe()
    }

    private func receive(_ reading: GeoReading) {
        lastReading = reading
        FlagImageStore.shared.prefetch(reading.primaryCountry)
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

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = await MainActor.run { [weak self] in
                    self?.settings.pollIntervalSeconds ?? Constants.defaultPollIntervalSeconds
                }
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in self?.handle(.tick) }
            }
        }
    }
}
