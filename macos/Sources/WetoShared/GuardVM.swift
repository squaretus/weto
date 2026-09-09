import Foundation
import Observation
import WetoCore
import WetoSystem

public enum GuardStatusColor: Equatable, Sendable {
    case green, yellow, red, grey
}

/// Корень цели, стоящий сейчас: то, что интерфейс показывает пилюлей с отсчётом.
public struct PausedProcess: Equatable, Sendable, Identifiable {
    public let pid: Int32
    public let targetName: String
    public let since: Date
    /// Терминал этой цели после SIGCONT не вернётся сам: фоновое задание.
    /// Пользователю — подсказка про `fg`.
    public let isBackgrounded: Bool

    public var id: Int32 { pid }

    public init(pid: Int32, targetName: String, since: Date, isBackgrounded: Bool) {
        self.pid = pid
        self.targetName = targetName
        self.since = since
        self.isBackgrounded = isBackgrounded
    }
}

/// Применяет фазы и эффекты, которые посчитал `GuardController`, и объясняет их
/// журналом. Сам не решает ничего: ни переходов, ни причин — только выполняет
/// над процессами то, что решил редьюсер, и пишет, что именно случилось.
@Observable
@MainActor
public final class GuardVM {

    public private(set) var phase: GuardPhase = .disabled
    public private(set) var lastReading: GeoReading?

    /// Что ответил каждый сервис в последней пробе — материал попапа.
    public private(set) var lastReport: GeoProbeReport?

    /// Идёт проверка, запрошенная пользователем.
    public private(set) var isProbing = false

    public private(set) var permissionFailure: String?
    public private(set) var runningTargets: [RunningTarget] = []

    /// Корни целей, стоящих сейчас.
    public private(set) var pausedProcesses: [PausedProcess] = []

    /// Когда истечёт потолок паузы. `nil` — цели не стоят.
    public var pauseDeadline: Date? {
        phase.pausedSince.map { $0.addingTimeInterval(Constants.pauseCeilingSeconds) }
    }

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let eventLog: EventLogStore
    @ObservationIgnored private let checkLog: CheckLogStore
    @ObservationIgnored private let snapshotReader: NetworkSnapshotReading
    @ObservationIgnored private let geoProbe: GeoProbing
    @ObservationIgnored private let locator: ProcessLocating
    @ObservationIgnored private let resolver: TargetResolving
    @ObservationIgnored private let signaler: ProcessSignaling
    @ObservationIgnored private let ledger: StoppedLedger
    @ObservationIgnored private let terminalLocator: TerminalLocating
    @ObservationIgnored private let notifier: GuardNotifying
    @ObservationIgnored private let events: NetworkEventSourcing
    @ObservationIgnored private let launchAgent: LaunchAgentManaging
    @ObservationIgnored private let now: () -> Date

    // Пара «причина + pid»: тот же процесс по той же причине второй записи
    // не заводит, а новый — заводит всегда. Дедупликация только по pid съедала бы
    // настоящую причину, пришедшую на смену «ещё не проверено».
    @ObservationIgnored private var recordedKills: Set<RecordedKill> = []

    // Причины, уже описанные в журнале в рамках текущего небезопасного эпизода.
    @ObservationIgnored private var recordedReasons: Set<String> = []

    // Происхождение показаний, с которым контроллер применил текущую фазу:
    // из только что ответившей пробы или из прошлого вердикта. Считает его
    // контроллер — он единственный знает, чем принято решение.
    @ObservationIgnored private var lastOrigin: VerdictOrigin?

    // Эпизод паузы: один id на всё время стояния — процесс остановлен один раз,
    // и вторая запись про тот же pid была бы тем же повтором, которого журнал
    // не допускает и при завершении стоявших целей. Поэтому pid из эпизода
    // при завершении новых записей не заводят — им дописывается исход.
    //
    // Причина у эпизода одна в каждый момент, но не навсегда: пока цели стоят,
    // редьюсер вправе сменить причину стояния (смена пути под паузой), и тогда
    // весь эпизод уточняется до той причины, которая его держит, — вместе
    // с разбором свежести. Уточняется, а не заводится заново: см. `refreshPauseEpisodeCause`.
    @ObservationIgnored private var pauseEpisodeID: UUID?
    @ObservationIgnored private var pausedEpisodePIDs: Set<Int32> = []
    @ObservationIgnored private var pauseStaleness: VerdictStaleness?
    @ObservationIgnored private var pauseEpisodeReason: String?

    private struct RecordedKill: Hashable {
        let pid: Int32
        let reason: String
    }

    @ObservationIgnored private var controller: GuardController!
    @ObservationIgnored private var enforcer: ProcessEnforcer!

    // Обход процессов, сделанный для текущего события: синхронное решение
    // обязано действовать по нему же, а не запускать второй обход.
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
        signaler: ProcessSignaling,
        // Не значение по умолчанию: `StoppedLedger` изолирован главным актором,
        // а выражение по умолчанию считается вне него.
        ledger: StoppedLedger? = nil,
        terminalLocator: TerminalLocating = TerminalLocator(),
        notifier: GuardNotifying,
        events: NetworkEventSourcing,
        launchAgent: LaunchAgentManaging = LaunchAgentController(),
        debounceInterval: TimeInterval = Constants.networkEventDebounceSeconds,
        now: @escaping () -> Date = Date.init
    ) {
        self.settings = settings
        self.eventLog = eventLog
        self.checkLog = checkLog
        self.snapshotReader = snapshotReader
        self.geoProbe = geoProbe
        self.locator = locator
        self.resolver = resolver
        self.signaler = signaler
        let ledger = ledger ?? StoppedLedger(storage: InMemoryStoppedLedger())
        self.ledger = ledger
        self.terminalLocator = terminalLocator
        self.notifier = notifier
        self.events = events
        self.launchAgent = launchAgent
        self.now = now

        self.enforcer = ProcessEnforcer(
            settings: settings,
            resolver: resolver,
            locator: locator,
            signaler: signaler,
            ledger: ledger,
            now: now
        )

        self.controller = GuardController(
            settings: settings,
            snapshotReader: snapshotReader,
            geoProbe: geoProbe,
            debounceInterval: debounceInterval,
            now: now,
            vpnAppStatus: { [weak self] in self?.vpnAppStatus() ?? .notChosen },
            onPhase: { [weak self] phase, effect, origin in self?.apply(phase, effect: effect, origin: origin) },
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
        // Учёт не прочитался — обязательство «вернуть остановленным SIGCONT» не выполнено.
        // Молча пустое чтение неотличимо от «возобновлять нечего», поэтому след остаётся
        // в журнале проверок: там же, где и остальная диагностика.
        if ledger.startedFromCorruptedFile {
            checkLog.record(CheckEvent(
                date: now(),
                trigger: .startupRecovery,
                outcome: .ledgerUnreadable,
                fingerprint: snapshotReader.snapshot().verdictFingerprint,
                detail: "учёт остановленных процессов не прочитан: возобновлять нечего"
            ))
        }

        // После падения: SIGCONT всем из учёта, кто ещё стоит и остался тем же процессом.
        enforcer.resumeOrphans()
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
        // Штатный выход: замороженных целей не оставляем.
        enforcer.resume()
        resolvePauseEpisode("возобновлено: охрана остановлена")
        pausedProcesses.removeAll()
        // Фаза обязана уйти вместе с целями: «Пауза», оставленная после остановки,
        // тикала бы отсчётом до потолка, которого никто больше не считает,
        // и `pauseDeadline` показывал бы интерфейсу стояние без стоящих.
        phase = .disabled
    }

    /// Цвет статуса для глаза. Стоящие цели — не полноценная зелёная защита,
    /// но и не доказанная опасность: жёлтый оставлен всему, что не доказано.
    public var statusColor: GuardStatusColor {
        switch phase {
        case .disabled: return .grey
        case .protected: return .green
        case .interference, .verifying, .paused: return .yellow
        case .danger: return .red
        }
    }

    public var currentCountryCode: String? {
        switch phase {
        case .disabled, .verifying:
            return nil
        case .protected(let reading), .interference(let reading, _):
            return reading.primaryCountry
        case .paused:
            return lastReading?.primaryCountry
        case .danger(let evidence):
            return evidence == .vpnAppNotRunning ? nil : lastReading?.primaryCountry
        }
    }

    /// Показать пользователю терминал стоящей цели: под паузой процесс не отвечает,
    /// и найти его окно самому — задача не для человека.
    @discardableResult
    public func showTerminal(for pid: Int32) -> Bool {
        terminalLocator.activateTerminal(owning: pid, in: (currentScan ?? enforcer.scan()).processes)
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

    /// Список живых целей — по уже снятому обходу, если он есть: событие охраны
    /// обслуживает один обход процессов, а не столько, сколько у него шагов.
    public func refreshRunningTargets() {
        runningTargets = enforcer.runningTargets(in: currentScan ?? enforcer.scan())
    }

    /// Считается по уже собранному списку: строка настроек не имеет права
    /// запускать собственный обход процессов на каждую цель.
    public func runningProcessCount(forTarget entry: String) -> Int {
        runningTargets
            .filter { $0.entry == entry }
            .reduce(0) { $0 + $1.processCount }
    }

    /// Что именно стоит за целью — и почему её не нашли, если не нашли.
    ///
    /// Одного «не найдено в системе» мало: имя ищется по списку каталогов,
    /// и не найтись оно может просто потому, что инструмент лежит в своём.
    /// Подсказка про полный путь — единственный выход, который у пользователя
    /// есть прямо сейчас.
    public func resolvedDescription(forTarget entry: String) -> String {
        guard let rule = resolver.resolve(entry) else {
            return entry.contains("/")
                ? "не найдено: по этому пути нет исполняемого файла"
                : "не найдено по имени — укажите полный путь к файлу"
        }
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

            // Цель запустилась под паузой или запретом — действие применяется сразу,
            // не дожидаясь такта.
            if !isVPNApp, phase.action != .run {
                applyCurrentAction()
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
                date: now(),
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

    // MARK: - Применение фазы

    /// Фаза принята — остаётся выполнить её над процессами и объяснить журналом.
    ///
    /// Обход процессов на всё применение один: своё событие приносит его с собой,
    /// а ответ пробы приходит вне события — тогда обход снимается здесь и служит
    /// и сигналам, и списку живых целей, и статусу VPN-приложения.
    private func apply(_ phase: GuardPhase, effect: GuardEffect, origin: VerdictOrigin?) {
        let ownsScan = currentScan == nil
        if ownsScan { currentScan = enforcer.scan(includingVPNApp: true) }
        defer { if ownsScan { currentScan = nil } }

        self.phase = phase
        lastOrigin = origin

        switch effect {
        case .pause: pauseTargets()
        case .resume: resumeTargets()
        case .terminate:
            if case .danger(let evidence) = phase { terminateTargets(evidence) }
        case .none: break
        }

        switch phase.action {
        case .run:
            watchdogTask?.cancel(); watchdogTask = nil
            // Цели снова работают — эпизод закрыт, и следующее завершение будет первым,
            // а не «запуском запрещён». Сброс на всех работающих фазах, а не на одной
            // «На страже»: «Помехи» — рабочий путь (429 от ipinfo приходит регулярно),
            // и завершение после них получало чужой `kind`, а при совпавшем pid
            // не получало ни записи, ни баннера. По той же причине здесь гаснет
            // и сообщение о нехватке прав: оно про сигналы, которых больше нет.
            permissionFailure = nil
            recordedKills.removeAll()
            recordedReasons.removeAll()
        case .pause, .terminate:
            startWatchdog()
        }
        refreshPauseEpisodeCause()
        refreshRunningTargets()
    }

    /// Сторож под паузой доводит новорождённых потомков, под запретом — новые запуски.
    ///
    /// Обход процессов свой, как и у `apply`: сигналы и отладочные показания записи
    /// обязаны описывать один момент. Сторож срабатывает как раз тогда, когда запись
    /// и создаётся, — на новорождённой цели.
    private func applyCurrentAction() {
        let ownsScan = currentScan == nil
        if ownsScan { currentScan = enforcer.scan(includingVPNApp: true) }
        defer { if ownsScan { currentScan = nil } }

        switch phase.action {
        case .pause: pauseTargets()
        case .terminate: if case .danger(let evidence) = phase { terminateTargets(evidence) }
        case .run: break
        }
    }

    /// Причина эпизода паузы человеческим текстом: она же уходит в журнал.
    private var pauseReasonText: String {
        switch phase {
        case .verifying(let cause): return "Подключение ещё не проверено: \(cause.displayText)"
        case .paused(_, let reason): return reason.displayText
        default: return phase.title
        }
    }

    /// Разбор свежести есть только у стоящей фазы «вердикта нет»: у паузы по молчанию
    /// сервисов вердикт как раз в силе, и терять ему нечего. Живёт он ровно на время
    /// объявления потери, поэтому спрашивается у контроллера в тот же миг.
    private var currentPauseStaleness: VerdictStaleness? {
        if case .verifying = phase { return controller.lastStaleness }
        return nil
    }

    /// Причина стояния способна смениться, пока цели стоят: смена пути под паузой
    /// переводит «Паузу» в «Проверку», заново запускает отсчёт потолка и не даёт
    /// никакого эффекта — цели и так стоят. Записи эпизода обязаны говорить то,
    /// что держит их сейчас: иначе завершение по потолку дописывалось бы к записям
    /// про давно прошедший таймаут, да ещё без разбора свежести, и по выгрузке
    /// выходило бы, что путь не менялся вовсе.
    ///
    /// Эпизод при этом один: процесс остановлен один раз, и второй набор записей
    /// про те же pid был бы ложью. Уточняется весь эпизод разом — ровно затем
    /// `refine` и заведён.
    private func refreshPauseEpisodeCause() {
        guard let episodeID = pauseEpisodeID, phase.action == .pause else { return }
        let reason = pauseReasonText
        let staleness = currentPauseStaleness
        // Такт, подтверждающий прежнюю причину, разбора свежести не несёт —
        // затирать им уже записанный нельзя.
        guard reason != pauseEpisodeReason || (staleness != nil && staleness != pauseStaleness) else { return }

        pauseEpisodeReason = reason
        if let staleness { pauseStaleness = staleness }
        eventLog.refine(
            episodeID: episodeID,
            reasonText: reason,
            diagnostics: currentDiagnostics(staleness: pauseStaleness)
        )
    }

    private func pauseTargets() {
        let outcome = enforcer.pause(currentScan ?? enforcer.scan())
        let refused = outcome.results.filter { !$0.isDelivered }
        permissionFailure = refused.isEmpty
            ? nil
            : "Не удалось приостановить процессы \(refused.map(\.pid)) — недостаточно прав"

        // Пилюля с отсчётом описывает то, что стоит сейчас: цель, умершая под паузой
        // сама или снятая с охраны, оставалась в списке с живым отсчётом и кнопкой
        // «Показать терминал», которой нечего показывать.
        let standing = Set(outcome.matched.map(\.pid))
        pausedProcesses.removeAll { !standing.contains($0.pid) }

        guard !outcome.fresh.isEmpty else { return }

        let episodeID = pauseEpisodeID ?? UUID()
        if pauseEpisodeID == nil {
            pauseEpisodeID = episodeID
            pauseEpisodeReason = pauseReasonText
            pauseStaleness = currentPauseStaleness
        }
        let moment = now()
        let diagnostics = currentDiagnostics(staleness: pauseStaleness)
        // Причина берётся у эпизода, а не у фазы: новорождённый под паузой обязан
        // встать в один ряд с остальными, а не принести свой текст.
        let reasonText = pauseEpisodeReason ?? pauseReasonText
        eventLog.record(outcome.fresh.map { process in
            KillEvent(
                episodeID: episodeID,
                date: moment,
                targetName: process.targetName,
                pid: process.pid,
                parentPID: process.parentPID,
                executablePath: process.executablePath,
                matchedBy: process.matchedBy,
                kind: .paused,
                reasonText: reasonText,
                ip: lastReading?.ip,
                country: lastReading?.primaryCountry,
                confirmedCountry: lastReading?.confirmedCountry,
                confirmSource: lastReading?.confirmSource?.rawValue,
                diagnostics: diagnostics
            )
        })
        pausedEpisodePIDs.formUnion(outcome.fresh.map(\.pid))

        for root in outcome.fresh where root.matchedBy == .rule {
            let backgrounded = outcome.plan.backgrounded.contains(root.pid)
            pausedProcesses.append(PausedProcess(pid: root.pid, targetName: root.targetName,
                                                 since: moment, isBackgrounded: backgrounded))
            if backgrounded { notifier.notifyBackgrounded(targetName: root.targetName) }
        }
    }

    private func resumeTargets() {
        enforcer.resume()
        if case .disabled = phase {
            resolvePauseEpisode("возобновлено: охрана выключена или целей нет")
            // Чтение самой фазы, а не последнее известное: паузу снимает конкретный
            // вердикт, и в исходе обязан стоять его адрес.
        } else if let reading = phase.reading ?? lastReading {
            resolvePauseEpisode("возобновлено: проверка подтвердила безопасный выход: "
                                + "\(reading.ip), \(reading.primaryCountry)")
        } else {
            resolvePauseEpisode("возобновлено: проверка подтвердила безопасный выход")
        }
        pausedProcesses.removeAll()
    }

    /// Исход эпизода паузы: записи те же, к ним дописывается, чем стояние кончилось.
    /// Без исхода запись навсегда остаётся с «подключение ещё не проверено»,
    /// и пауза выглядит случайной.
    private func resolvePauseEpisode(_ outcome: String) {
        guard let episodeID = pauseEpisodeID else { return }
        eventLog.refine(
            episodeID: episodeID,
            resolutionText: outcome,
            ip: lastReading?.ip,
            country: lastReading?.primaryCountry,
            confirmedCountry: lastReading?.confirmedCountry,
            confirmSource: lastReading?.confirmSource?.rawValue,
            diagnostics: currentDiagnostics(staleness: pauseStaleness)
        )
        pauseEpisodeID = nil
        pausedEpisodePIDs.removeAll()
        pauseStaleness = nil
        pauseEpisodeReason = nil
    }

    private func terminateTargets(_ evidence: UnsafeEvidence) {
        let outcome = enforcer.terminate(currentScan ?? enforcer.scan())
        let matched = outcome.matched
        let refused = outcome.results.filter { !$0.isDelivered }
        permissionFailure = refused.isEmpty
            ? nil
            : "Не удалось завершить процессы \(refused.map(\.pid)) — недостаточно прав"

        let terminated = Set(outcome.results.filter(\.isDelivered).map(\.pid))
        let reasonKey = evidence.displayText
        let isNewReason = !recordedReasons.contains(reasonKey)

        // Исход эпизода паузы: те же pid новых записей не заводят.
        let skip = pausedEpisodePIDs
        let prefix = evidence == .pauseExpired ? "завершено по потолку" : "завершено по доказательству"
        resolvePauseEpisode("\(prefix): \(reasonKey)")
        pausedProcesses.removeAll()

        // Уведомление — про то, что действительно завершено сейчас, включая цели,
        // стоявшие на паузе: запись у них уже есть, но новость «цели завершены»
        // от этого не исчезает.
        let killedNow = matched.filter { terminated.contains($0.pid) }
        let fresh = matched.filter {
            terminated.contains($0.pid) && !skip.contains($0.pid)
                && !recordedKills.contains(RecordedKill(pid: $0.pid, reason: reasonKey))
        }
        if !killedNow.isEmpty, isNewReason || !fresh.isEmpty {
            notifier.notifyTerminated(reasonText: "\(Self.targetsSummary(of: killedNow)): \(reasonKey)",
                                      killedCount: killedNow.count)
        }
        // Причина и завершённые pid запоминаются независимо от записи: иначе сторож
        // раз в 250 мс повторял бы и уведомление, и записи про уже мёртвые процессы.
        if !killedNow.isEmpty {
            recordedReasons.insert(reasonKey)
            recordedKills.formUnion(killedNow.map { RecordedKill(pid: $0.pid, reason: reasonKey) })
        }
        guard !fresh.isEmpty else { return }

        let kind: KillEventKind = isNewReason ? .terminated : .launchBlocked

        // Один проход охраны — один эпизод: сколько процессов завершено,
        // столько и записей, и все они помнят, что это было одно событие.
        let episodeID = UUID()
        let moment = now()
        let diagnostics = currentDiagnostics(staleness: nil)
        eventLog.record(fresh.map { process in
            KillEvent(
                episodeID: episodeID,
                date: moment,
                targetName: process.targetName,
                pid: process.pid,
                parentPID: process.parentPID,
                executablePath: process.executablePath,
                matchedBy: process.matchedBy,
                kind: kind,
                reasonText: reasonKey,
                ip: lastReading?.ip,
                country: lastReading?.primaryCountry,
                confirmedCountry: lastReading?.confirmedCountry,
                confirmSource: lastReading?.confirmSource?.rawValue,
                diagnostics: diagnostics
            )
        })
    }

    /// Отладочные показания эпизода: они не показываются пользователю и нужны
    /// только выгрузке. `staleness` называется явно вызывающим: только пауза
    /// «вердикта нет» знает, что именно устарело.
    private func currentDiagnostics(staleness: VerdictStaleness?) -> KillDiagnostics {
        let snapshot = controller.lastSnapshot
        return KillDiagnostics(
            staleness: staleness,
            outgoingInterface: snapshot?.outgoing?.interface,
            outgoingAddress: snapshot?.outgoing?.address,
            hasNetworkPath: lastReport?.hasNetworkPath,
            vpnAppEntry: settings.vpnAppRule,
            vpnAppStatus: String(describing: vpnAppStatus()),
            // Происхождение приходит от контроллера: он один знает, чем принято решение.
            verdictOrigin: lastReading == nil ? nil : lastOrigin,
            services: lastReport?.traces ?? [],
            probedAt: lastReport?.checkedAt,
            appVersion: Constants.appVersion
        )
    }

    /// «claude ×34, codex» — цели прохода с числом процессов там, где их больше одного.
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

    /// Сторож: под паузой ловит новорождённых потомков, под запретом — новые запуски.
    /// Живого системного события про запуск терминального процесса не существует.
    private func startWatchdog() {
        guard watchdogTask == nil else { return }
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Constants.watchdogIntervalSeconds))
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in self?.applyCurrentAction() }
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
