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
    private var resolvedAt: Date?
    private var lastKnownRules: [String: TargetRule] = [:]

    private var cachedVPNEntry: String??
    private var cachedVPNRule: TargetRule?
    private var vpnResolvedAt: Date?

    private let now: () -> Date

    init(
        settings: SettingsStore,
        resolver: TargetResolving,
        locator: ProcessLocating,
        killer: ProcessKilling,
        now: @escaping () -> Date = Date.init
    ) {
        self.settings = settings
        self.resolver = resolver
        self.locator = locator
        self.killer = killer
        self.now = now
    }

    /// Разрешение цели в правило лезет в файловую систему и LaunchServices,
    /// поэтому кэшируется. Но кэша по одному лишь списку целей мало: путь
    /// бинарника, развёрнутый через симлинки, меняется при каждом обновлении
    /// инструмента, и правило устаревало молча до повторного добавления цели.
    /// Отсюда второй повод пересчитать — истёкший `targetRuleRefreshSeconds`.
    func rules() -> [TargetRule] {
        let entries = settings.targets
        let moment = now()
        let isStale = resolvedAt.map {
            moment.timeIntervalSince($0) >= Constants.targetRuleRefreshSeconds
        } ?? true

        if entries != cachedEntries || isStale {
            cachedEntries = entries
            lastKnownRules = lastKnownRules.filter { entries.contains($0.key) }
            cachedRules = entries.compactMap(resolve)
            resolvedAt = moment
        }
        return cachedRules
    }

    /// Правило помнит пути, по которым цель запускалась раньше. Сеанс, начатый
    /// до обновления, продолжает жить на прежнем бинарнике, и `proc_pidpath`
    /// сообщает про него старый путь: без памяти переезд правила на новую версию
    /// выпускал бы такой процесс из-под охраны. Забытый путь уже не существует
    /// на диске, поэтому новый процесс по нему появиться не может.
    ///
    /// По той же причине неудача разрешения не удаляет правило: пока файл
    /// подменяют, цель на мгновение не разрешается ни во что, а живой процесс
    /// в этот момент никуда не девается. Пустой список целей — только тот,
    /// который выбрал пользователь.
    private func resolve(_ entry: String) -> TargetRule? {
        guard let rule = resolver.resolve(entry) else { return lastKnownRules[entry] }

        let remembered = TargetRule(
            entry: rule.entry,
            displayName: rule.displayName,
            kind: rule.kind,
            path: rule.path,
            launchPaths: rule.launchPaths + (lastKnownRules[entry]?.launchPaths ?? [])
        )
        lastKnownRules[entry] = remembered
        return remembered
    }

    /// Правило выбранного VPN-приложения. Разрешается тем же путём, что цели,
    /// и кэшируется по тому же поводу: у клиента, обновившегося через собственный
    /// апдейтер, путь меняется целиком, а правило, разрешённое однажды, молча
    /// перестало бы совпадать с чем-либо — и охрана решила бы, что VPN закрыт.
    ///
    /// В `Scan.rules` это правило не попадает никогда: там ровно то, что `enforce`
    /// имеет право завершать, а завершать собственный источник защиты нельзя.
    func vpnAppRule() -> TargetRule? {
        let entry = settings.vpnAppRule
        let moment = now()
        let isStale = vpnResolvedAt.map {
            moment.timeIntervalSince($0) >= Constants.targetRuleRefreshSeconds
        } ?? true

        if cachedVPNEntry != entry || isStale {
            cachedVPNEntry = entry
            cachedVPNRule = entry.flatMap(resolve)
            vpnResolvedAt = moment
        }
        return cachedVPNRule
    }

    func invalidateRuleCache() {
        cachedEntries = nil
        cachedVPNEntry = nil
    }

    /// Один обход процессов на событие.
    ///
    /// `includingVPNApp` не добавляет правило в скан, а лишь учитывает его в двух
    /// вопросах: нужен ли argv (VPN-клиент может оказаться скриптом с shebang)
    /// и нужен ли обход вообще, когда целей ещё нет.
    func scan(includingVPNApp: Bool = false) -> Scan {
        let rules = rules()
        let vpnRule = includingVPNApp ? vpnAppRule() : nil
        guard !rules.isEmpty || vpnRule != nil else { return Scan(processes: [], rules: []) }

        let needsArguments = (rules + [vpnRule].compactMap { $0 }).contains { $0.kind == .script }
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
