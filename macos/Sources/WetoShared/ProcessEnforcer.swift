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
        let results: [SignalResult]

        static let none = EnforcementResult(matched: [], results: [])
    }

    struct PauseOutcome {
        let plan: PausePlan
        /// Цели, остановленные этим проходом: без шеллов и без уже стоявших.
        let fresh: [MatchedProcess]
        let results: [SignalResult]

        static let none = PauseOutcome(
            plan: PausePlan(stopOrder: [], shells: [], backgrounded: [], skipped: []), fresh: [], results: []
        )
    }

    private let settings: SettingsStore
    private let resolver: TargetResolving
    private let locator: ProcessLocating
    private let signaler: ProcessSignaling
    private let ledger: StoppedLedger

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
        signaler: ProcessSignaling,
        ledger: StoppedLedger,
        now: @escaping () -> Date = Date.init
    ) {
        self.settings = settings
        self.resolver = resolver
        self.locator = locator
        self.signaler = signaler
        self.ledger = ledger
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

    /// Пауза: только тем, кого в учёте ещё нет. Под паузой обход идёт каждые 250 мс,
    /// и ребёнок, родившийся между снимком и сигналом, доловится следующим проходом.
    func pause(_ scan: Scan) -> PauseOutcome {
        guard !scan.isEmpty else { return .none }
        let matched = ProcessMatcher.matches(in: scan.processes, rules: scan.rules)
        let known = Set(ledger.pids)
        let pending = matched.filter { !known.contains($0.pid) }
        guard !pending.isEmpty else { return .none }

        let plan = PausePlanner.plan(matched: pending, processes: scan.processes)
        let order = plan.stopOrder.filter { !known.contains($0) }
        let results = signaler.send(.stop, to: order)
        let delivered = Set(results.filter(\.isDelivered).map(\.pid))

        var pathByPID: [Int32: String] = [:]
        for process in scan.processes { pathByPID[process.pid] = process.executablePath }
        let moment = now()
        ledger.add(order.filter(delivered.contains).map { pid in
            StoppedProcess(pid: pid, executablePath: pathByPID[pid] ?? "", stoppedAt: moment,
                           isShell: plan.shells.contains(pid))
        })

        return PauseOutcome(plan: plan, fresh: pending.filter { delivered.contains($0.pid) }, results: results)
    }

    /// Продолжение всем из учёта — в обратном порядке: потомки, цели, шеллы.
    @discardableResult
    func resume() -> [SignalResult] {
        let order = Array(ledger.pids.reversed())
        guard !order.isEmpty else { return [] }
        let results = signaler.send(.resume, to: order)
        ledger.clear()
        return results
    }

    /// После падения weto: продолжить только тех, кто всё ещё стоит и остался тем же процессом.
    /// pid переиспользуются, и SIGCONT чужому процессу недопустим.
    ///
    /// Учёт на диске не несёт глубины дерева — только `isShell`, поэтому точный
    /// «потомки, затем цель, затем шелл» здесь недостижим; ближайшее приближение —
    /// все цели раньше своих шеллов, порядок внутри каждой группы как в файле.
    func resumeOrphans() {
        let entries = ledger.entries
        guard !entries.isEmpty else { return }
        var alive: [Int32: ProcessSnapshot] = [:]
        for process in locator.allProcesses() { alive[process.pid] = process }
        let ours = entries.filter { entry in
            guard let process = alive[entry.pid] else { return false }
            return process.isStopped && process.executablePath == entry.executablePath
        }
        if !ours.isEmpty {
            let order = ours.filter { !$0.isShell }.map(\.pid) + ours.filter(\.isShell).map(\.pid)
            _ = signaler.send(.resume, to: order)
        }
        ledger.clear()
    }

    /// Завершение. Шелл, стоявший ради терминала цели, обязан ожить: цели больше нет.
    /// Недоставленный SIGKILL оставляет процесс в учёте — штатный выход его продолжит.
    func terminate(_ scan: Scan) -> EnforcementResult {
        let matched = scan.isEmpty ? [] : ProcessMatcher.matches(in: scan.processes, rules: scan.rules)
        let results = matched.isEmpty ? [] : signaler.send(.kill, to: matched.map(\.pid))
        let killed = Set(results.filter(\.isDelivered).map(\.pid))

        let shells = ledger.entries.filter(\.isShell).map(\.pid)
        if !shells.isEmpty { _ = signaler.send(.resume, to: shells.reversed()) }
        ledger.remove(shells + ledger.pids.filter(killed.contains))

        return EnforcementResult(matched: matched, results: results)
    }

    func runningTargets(in scan: Scan) -> [RunningTarget] {
        guard !scan.isEmpty else { return [] }
        return ProcessMatcher.runningTargets(in: scan.processes, rules: scan.rules)
    }
}
