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

    /// Итог продолжения. Обязательство «вернуть из паузы» снимает не отправка сигнала,
    /// а наблюдение: `kill(SIGCONT)` возвращает 0 и для цели, у которой шелл уже забрал
    /// терминал, — она просыпается, тут же читает tty, получает SIGTTIN и встаёт обратно.
    /// Учёт, вычеркнутый по факту отправки, оставлял такую цель замороженной навсегда:
    /// держать обязательство было больше некому, а журнал писал «возобновлено».
    struct ResumeOutcome {
        /// Что сказало ядро на каждый посланный SIGCONT.
        let results: [SignalResult]
        /// Обязательство снято наблюдением: процесса больше нет (или его pid достался
        /// другому) либо ядро показало его идущим.
        let released: [Int32]
        /// Остались в учёте: ядро всё ещё показывает их стоящими. Фоновое задание
        /// попадает сюда снова и снова — оно просыпается на SIGCONT, читает tty,
        /// получает SIGTTIN и встаёт обратно, пока пользователь не введёт `fg`.
        let unresolved: [StoppedProcess]

        var isComplete: Bool { unresolved.isEmpty }

        static let none = ResumeOutcome(results: [], released: [], unresolved: [])
    }

    struct PauseOutcome {
        let plan: PausePlan
        /// Цели, остановленные этим проходом: без шеллов и без уже стоявших. Ожившая
        /// запись учёта сюда входит — её остановили заново, и это событие.
        let fresh: [MatchedProcess]
        /// Шеллы, остановленные этим проходом ради терминала своей цели. Целями они
        /// не являются, но SIGSTOP получили — и journal обязан объяснить каждый SIGSTOP,
        /// поэтому они приезжают сюда готовой записью: имя цели, родитель, путь
        /// и `matchedBy == .shell`.
        let freshShells: [MatchedProcess]
        let results: [SignalResult]
        /// Всё, что под правилами прямо сейчас, — включая стоящих с прошлых проходов.
        /// По нему видно, кто из стоящих больше не существует или перестал быть целью:
        /// список пилюль с отсчётом обязан описывать настоящее, а не историю.
        let matched: [MatchedProcess]

        static let none = PauseOutcome(
            plan: PausePlan(stopOrder: [], shells: [], backgrounded: [], skipped: []),
            fresh: [], freshShells: [], results: [], matched: []
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

    /// Ключ «уже стоит по нашей вине»: pid один переиспользуется ядром, и учёт хранит
    /// путь бинарника именно ради этого — сравнение обязано идти по паре, не по pid одному.
    private struct StoppedIdentity: Hashable {
        let pid: Int32
        let executablePath: String
    }

    /// Пауза: только тем, кого в учёте ещё нет. Под паузой обход идёт каждые 250 мс,
    /// и ребёнок, родившийся между снимком и сигналом, доловится следующим проходом.
    func pause(_ scan: Scan) -> PauseOutcome {
        guard !scan.isEmpty else { return .none }
        let matched = ProcessMatcher.matches(in: scan.processes, rules: scan.rules)

        var snapshotByPID: [Int32: ProcessSnapshot] = [:]
        for process in scan.processes { snapshotByPID[process.pid] = process }

        // pid, доставшийся от переиспользования, не значит «тот же процесс, что мы
        // остановили»: запись в учёте про мёртвого владельца этого pid не должна
        // маскировать свежую цель, которой ядро выдало то же число.
        //
        // Записи мало и по второй причине: с тех пор как учёт держит обязательство до
        // наблюдения, в нём остаётся и цель, которой SIGCONT уже дошёл. Она снова идёт,
        // и «мы её уже остановили» по одной записи выпустило бы работающую цель
        // из-под паузы. Решает снимок: стоит она или нет — видно у ядра.
        let known = Set(ledger.entries.map { StoppedIdentity(pid: $0.pid, executablePath: $0.executablePath) })
        func isKnown(_ pid: Int32) -> Bool {
            guard let process = snapshotByPID[pid] else { return false }
            return known.contains(StoppedIdentity(pid: pid, executablePath: process.executablePath))
        }
        func isAlreadyStopped(_ pid: Int32) -> Bool {
            snapshotByPID[pid]?.isStopped == true && isKnown(pid)
        }

        let pending = matched.filter { !isAlreadyStopped($0.pid) }
        // Останавливать некого — но кто под правилами, знать всё равно нужно:
        // ровно этот проход и обнаруживает, что стоящая цель умерла сама.
        guard !pending.isEmpty else {
            return PauseOutcome(plan: PausePlan(stopOrder: [], shells: [], backgrounded: [], skipped: []),
                                fresh: [], freshShells: [], results: [], matched: matched)
        }

        let plan = PausePlanner.plan(matched: pending, processes: scan.processes)
        let order = plan.stopOrder.filter { !isAlreadyStopped($0) }
        let results = signaler.send(.stop, to: order)
        let delivered = Set(results.filter(\.isDelivered).map(\.pid))

        let moment = now()
        ledger.add(order.filter(delivered.contains).map { pid in
            StoppedProcess(pid: pid, executablePath: snapshotByPID[pid]?.executablePath ?? "",
                           stoppedAt: moment, isShell: plan.shells.contains(pid))
        })

        // Остановлены этим проходом — все, кому доставлен SIGSTOP, включая ожившую запись
        // учёта: она шла, значит останавливаем её заново, и это событие, а не повтор.
        // Отбор «про этот pid эпизод уже рассказал» живёт слоем выше, у эпизода
        // (`GuardVM.pausedEpisodePIDs`): здесь его хватало ровно до конца эпизода,
        // а цель, остановленную заново уже в следующем, глушило совсем — ни записи,
        // ни пилюли, ни уведомления про честно стоящий процесс.
        // Шелл — не цель, но остановлен он нами, и запись о нём обязана быть такой же
        // полной: имя цели, ради терминала которой он встал, его родитель и путь.
        let freshShells: [MatchedProcess] = plan.shells.filter(delivered.contains).map { pid in
            MatchedProcess(
                pid: pid,
                targetName: plan.shellTargets[pid] ?? "",
                parentPID: snapshotByPID[pid]?.parentPID ?? 0,
                executablePath: snapshotByPID[pid]?.executablePath ?? "",
                matchedBy: .shell
            )
        }

        return PauseOutcome(plan: plan, fresh: pending.filter { delivered.contains($0.pid) },
                            freshShells: freshShells, results: results, matched: matched)
    }

    /// Кого учёт всё ещё держит, а кого отпускает: `nil` в снимке — процесса нет,
    /// чужой путь по тому же pid — тоже нет (число переиспользовано ядром).
    private func settle(
        _ entries: [StoppedProcess],
        against alive: [Int32: ProcessSnapshot]
    ) -> (living: [StoppedProcess], standing: [StoppedProcess], released: [Int32]) {
        var living: [StoppedProcess] = []
        var standing: [StoppedProcess] = []
        var released: [Int32] = []
        for entry in entries {
            guard let process = alive[entry.pid], process.executablePath == entry.executablePath else {
                released.append(entry.pid)
                continue
            }
            living.append(entry)
            if process.isStopped { standing.append(entry) } else { released.append(entry.pid) }
        }
        return (living, standing, released)
    }

    /// Наблюдать обязательство можно только по настоящему обходу. `scan()` при пустом
    /// списке правил возвращает пустой снимок — обходить незачем, — и по нему все записи
    /// учёта выглядели бы исчезнувшими, а это ровно те, которых забывать нельзя.
    /// Настоящий обход пустым не бывает: в нём есть как минимум launchd.
    private func observedProcesses(_ scan: Scan?) -> [ProcessSnapshot] {
        guard let processes = scan?.processes, !processes.isEmpty else { return locator.allProcesses() }
        return processes
    }

    /// Продолжение всем из учёта — в обратном порядке: потомки, цели, шеллы.
    ///
    /// Обязательство снимает наблюдение, а не отправка сигнала. `kill(SIGCONT)` возвращает
    /// 0 и для фонового задания: цель просыпается, тут же читает tty, получает SIGTTIN
    /// и встаёт обратно. Учёт, вычеркнутый по факту отправки, оставлял её замороженной
    /// навсегда — слать ей SIGCONT было больше некому, — а журнал писал «возобновлено».
    ///
    /// Наблюдение идёт по обходу, снятому до сигналов: увидеть последствия SIGCONT в тот
    /// же миг нельзя — процесс успеет проснуться и встать уже после нашего чтения.
    /// Поэтому проход, отправивший сигнал, обязательства не снимает; разбирает его
    /// следующий, и всё ещё стоящая цель получает SIGCONT снова.
    ///
    /// `skipping` — записи, которым досылать сигнал перестали: настоящее фоновое задание
    /// отвечает стопом на каждый SIGCONT, а `notify` у zsh включён по умолчанию и печатает
    /// пользователю `suspended (tty input)` раз в секунду до самого `fg`. Из учёта такая
    /// запись не уходит: обязательство остаётся, его исполнят `terminate` и штатный выход.
    @discardableResult
    func resume(observing scan: Scan? = nil, skipping: Set<Int32> = []) -> ResumeOutcome {
        let entries = ledger.entries
        guard !entries.isEmpty else { return .none }

        var alive: [Int32: ProcessSnapshot] = [:]
        for process in observedProcesses(scan) { alive[process.pid] = process }
        let (living, standing, released) = settle(entries, against: alive)

        // Сигнал уходит всем живым записям, а не только стоящим: наблюдение снимает
        // обязательство, но порядок «потомки, цели, шеллы» — часть контракта, и рвать
        // его из-за одной записи, успевшей проснуться, нельзя.
        let order = living.map(\.pid).reversed().filter { !skipping.contains($0) }
        let results = order.isEmpty ? [] : signaler.send(.resume, to: order)
        if !released.isEmpty { ledger.remove(released) }
        return ResumeOutcome(results: results, released: released, unresolved: standing)
    }

    /// После падения weto: продолжить только тех, кто всё ещё стоит и остался тем же процессом.
    /// pid переиспользуются, и SIGCONT чужому процессу недопустим.
    ///
    /// Порядок — точный обратный, как и в `resume`: файл учёта хранит записи в порядке
    /// добавления, а добавляет их `pause` ровно в порядке отправки SIGSTOP («шеллы,
    /// затем цели и потомки»). То есть подлинный стоп-порядок доезжает до нового запуска
    /// сам, и восстанавливать его приближением («не-шеллы раньше шеллов») незачем:
    /// приближение переставляло цель и её потомка местами, а порядок сигналов — контракт.
    /// Глубину дерева знать для этого не нужно, нужен лишь порядок, в котором стопы ушли.
    ///
    /// Обход тот же самый, что уезжает вызывающему: `surfaceRecovered` показывает
    /// пользователю стоящие цели по нему, а не вторым проходом по всем процессам.
    /// Обход здесь настоящий даже при пустом списке правил — обязательство «вернуть
    /// из паузы» от наличия целей не зависит, а `scan()` без правил не обходит ничего.
    ///
    /// Запись, которую этот проход не разрешил, из учёта не уходит: обязательство и здесь
    /// снимает наблюдение. Дальше её ведёт обычный такт охраны — он и досылает SIGCONT
    /// цели, вернувшейся в стоп по SIGTTIN.
    @discardableResult
    func resumeOrphans() -> (outcome: ResumeOutcome, observed: Scan) {
        let rules = rules()
        let entries = ledger.entries
        guard !entries.isEmpty else { return (.none, Scan(processes: [], rules: rules)) }

        let needsArguments = rules.contains { $0.kind == .script }
        let processes = locator.allProcesses(includeArguments: needsArguments)
        var alive: [Int32: ProcessSnapshot] = [:]
        for process in processes { alive[process.pid] = process }
        let (_, standing, released) = settle(entries, against: alive)

        var results: [SignalResult] = []
        if !standing.isEmpty {
            results = signaler.send(.resume, to: standing.map(\.pid).reversed())
        }
        if !released.isEmpty { ledger.remove(released) }
        return (
            ResumeOutcome(results: results, released: released, unresolved: standing),
            Scan(processes: processes, rules: rules)
        )
    }

    /// Завершение стоящих целей: SIGKILL тем, кто под правилом, SIGCONT всем остальным
    /// из учёта — шеллу, стоявшему ради терминала цели, и любому, кто перестал совпадать
    /// с правилом между паузой и завершением. Оставить его стоять значило бы заморозить
    /// процесс до следующего запуска weto: под доказательством SIGCONT не пошлёт уже никто.
    ///
    /// Недоставленный SIGKILL оставляет цель в учёте — штатный выход её продолжит.
    /// Продолженная запись уходит из учёта по тому же правилу, что и в `resume`:
    /// по наблюдению, а не по отправке сигнала. Стоящей она остаётся до тех пор,
    /// пока ядро не покажет её идущей, и сторож досылает SIGCONT каждым проходом.
    func terminate(_ scan: Scan) -> EnforcementResult {
        let matched = scan.isEmpty ? [] : ProcessMatcher.matches(in: scan.processes, rules: scan.rules)
        let results = matched.isEmpty ? [] : signaler.send(.kill, to: matched.map(\.pid))
        let killed = Set(results.filter(\.isDelivered).map(\.pid))

        let doomed = Set(matched.map(\.pid))
        var alive: [Int32: ProcessSnapshot] = [:]
        for process in observedProcesses(scan) { alive[process.pid] = process }
        let (living, _, released) = settle(ledger.entries.filter { !doomed.contains($0.pid) }, against: alive)
        if !living.isEmpty { _ = signaler.send(.resume, to: Array(living.map(\.pid).reversed())) }
        ledger.remove(released + ledger.pids.filter(killed.contains))

        return EnforcementResult(matched: matched, results: results)
    }

    func runningTargets(in scan: Scan) -> [RunningTarget] {
        guard !scan.isEmpty else { return [] }
        return ProcessMatcher.runningTargets(in: scan.processes, rules: scan.rules)
    }
}
