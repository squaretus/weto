import Foundation
import WetoCore
import WetoSystem

/// Один обход процессов на событие плюс кэш разрешённых правил.
///
/// До этого `handle` сканировал процессы для UI, `enforce` — ещё раз для убийства,
/// и третий раз после kill: до четырёх полных обходов в секунду в небезопасном
/// состоянии, каждый на главном акторе. argv читается только при наличии
/// скриптовых целей — для остальных это лишний sysctl на каждый процесс.
@MainActor
final class ProcessEnforcer {

    struct Scan {
        let processes: [ProcessSnapshot]
        let rules: [TargetRule]

        var isEmpty: Bool { rules.isEmpty }
    }

    struct EnforcementResult {
        let matched: [MatchedProcess]
        let results: [KillResult]

        static let none = EnforcementResult(matched: [], results: [])
    }

    private let settings: SettingsStore
    private let resolver: TargetResolving
    private let locator: ProcessLocating
    private let killer: ProcessKilling

    private var cachedEntries: [String]?
    private var cachedRules: [TargetRule] = []

    init(
        settings: SettingsStore,
        resolver: TargetResolving,
        locator: ProcessLocating,
        killer: ProcessKilling
    ) {
        self.settings = settings
        self.resolver = resolver
        self.locator = locator
        self.killer = killer
    }

    /// Разрешение цели в правило лезет в файловую систему и LaunchServices,
    /// поэтому пересчитывается только при смене списка целей.
    func rules() -> [TargetRule] {
        let entries = settings.targets
        if entries != cachedEntries {
            cachedEntries = entries
            cachedRules = entries.compactMap(resolver.resolve)
        }
        return cachedRules
    }

    func invalidateRuleCache() {
        cachedEntries = nil
    }

    func scan() -> Scan {
        let rules = rules()
        guard !rules.isEmpty else { return Scan(processes: [], rules: []) }

        let needsArguments = rules.contains { $0.kind == .script }
        return Scan(
            processes: locator.allProcesses(includeArguments: needsArguments),
            rules: rules
        )
    }

    func enforce(_ scan: Scan) -> EnforcementResult {
        guard !scan.isEmpty else { return .none }

        let matched = ProcessMatcher.matches(in: scan.processes, rules: scan.rules)
        guard !matched.isEmpty else { return .none }

        return EnforcementResult(matched: matched, results: killer.kill(pids: matched.map(\.pid)))
    }

    func runningTargets(in scan: Scan) -> [RunningTarget] {
        guard !scan.isEmpty else { return [] }
        return ProcessMatcher.runningTargets(in: scan.processes, rules: scan.rules)
    }
}
