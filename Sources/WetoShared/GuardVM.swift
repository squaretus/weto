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

    public func flag(lastReading: GeoReading?) -> String {
        switch self {
        case .disabled:
            return CountryFlag.unknown
        case .safe(let reading):
            return CountryFlag.emoji(for: reading?.primaryCountry ?? "")
        case .unsafe(let reason):
            switch reason {
            case .vpnNotConfigured, .vpnDown, .vpnNotPrimary, .geoUnavailable:
                return CountryFlag.unknown
            default:
                return CountryFlag.emoji(for: lastReading?.primaryCountry ?? "")
            }
        }
    }
}

@Observable
@MainActor
public final class GuardVM {

    public private(set) var state: GuardState = .disabled
    public private(set) var lastReading: GeoReading?

    public private(set) var permissionFailure: String?
    public private(set) var availableVPNNames: [String] = []

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let eventLog: EventLogStore
    @ObservationIgnored private let snapshotReader: NetworkSnapshotReading
    @ObservationIgnored private let geoProbe: GeoProbing
    @ObservationIgnored private let locator: ProcessLocating
    @ObservationIgnored private let resolver: TargetResolving
    @ObservationIgnored private let killer: ProcessKilling
    @ObservationIgnored private let notifier: KillNotifying
    @ObservationIgnored private let events: NetworkEventSourcing
    @ObservationIgnored private let debounceInterval: TimeInterval

    @ObservationIgnored private var recordedPIDs: Set<Int32> = []

    @ObservationIgnored private var probeTask: Task<Void, Never>?
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
        self.debounceInterval = debounceInterval
    }

    deinit {
        probeTask?.cancel()
        tickTask?.cancel()
        watchdogTask?.cancel()
    }

    public func start() {
        refreshVPNNames()
        events.start { [weak self] trigger in
            Task { @MainActor [weak self] in self?.handle(trigger) }
        }
        startTicking()
        handle(.tick)
    }

    public func stop() {
        events.stop()
        probeTask?.cancel(); probeTask = nil
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

    public func unloadCompletely() {
        stop()
        LaunchAgentController.disable()
    }

    public func refreshVPNNames() {
        availableVPNNames = snapshotReader.snapshot().vpnCandidateNames
    }

    public func runningProcessCount(forTarget entry: String) -> Int {
        guard let rule = resolver.resolve(entry) else { return 0 }
        return ProcessMatcher.pids(
            in: locator.allProcesses(includeArguments: rule.kind == .script),
            rules: [rule]
        ).count
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
        if case .appLaunched(let bundleID) = trigger {

            guard settings.targets.contains(bundleID) else { return }

            if case .unsafe(let reason) = state {
                enforce(reason: reason)
                return
            }
        }

        let config = settings.guardConfig
        let vpn = VPNStatusResolver.status(
            serviceName: config.vpnServiceName,
            in: snapshotReader.snapshot()
        )

        if let local = GuardPolicy.decideLocal(
            isEnabled: settings.isEnabled,
            vpn: vpn,
            config: config
        ) {
            apply(local)
            return
        }

        scheduleProbe()
    }

    public func awaitPendingProbe() async {
        await probeTask?.value
    }

    private func scheduleProbe() {
        let interval = debounceInterval
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            await self?.runProbe()
        }
    }

    public func runProbe() async {
        let config = settings.guardConfig
        let vpn = VPNStatusResolver.status(
            serviceName: config.vpnServiceName,
            in: snapshotReader.snapshot()
        )
        let geo = await geoProbe.probe()

        if case .resolved(let reading) = geo {
            lastReading = reading

            FlagImageStore.shared.prefetch(reading.primaryCountry)
        }

        apply(GuardPolicy.decide(GuardSignals(
            isEnabled: settings.isEnabled,
            vpn: vpn,
            geo: geo,
            config: config
        )))
    }

    private func apply(_ decision: GuardDecision) {
        switch decision {
        case .safe:
            watchdogTask?.cancel(); watchdogTask = nil
            permissionFailure = nil
            recordedPIDs.removeAll()
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
        let rules = settings.targets.compactMap(resolver.resolve)
        guard !rules.isEmpty else { return }

        let needsArguments = rules.contains { $0.kind == .script }
        let matched = ProcessMatcher.matches(
            in: locator.allProcesses(includeArguments: needsArguments),
            rules: rules
        )
        guard !matched.isEmpty else { return }

        let results = killer.kill(pids: matched.map(\.pid))
        let refused = results.filter { !$0.isTerminated }
        permissionFailure = refused.isEmpty
            ? nil
            : "Не удалось завершить процессы \(refused.map(\.pid)) — недостаточно прав"

        let terminated = Set(results.filter(\.isTerminated).map(\.pid))
        let fresh = matched.filter { terminated.contains($0.pid) && !recordedPIDs.contains($0.pid) }
        guard !fresh.isEmpty else { return }

        let kind: KillEventKind = recordedPIDs.isEmpty ? .terminated : .launchBlocked
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
