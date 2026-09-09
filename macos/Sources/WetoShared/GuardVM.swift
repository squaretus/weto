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
    /// Когда weto остановил этот pid в текущем стоянии. Отсчёт до потолка интерфейс берёт
    /// не отсюда, а из фазы редьюсера (`GuardVM.pauseDeadline` → `phase.pausedSince`):
    /// потолок принадлежит эпизоду, а не отдельной цели. Сегодня поле никем не читается —
    /// это запись факта для выгрузки и будущей строки «стоит с 17:16».
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
    // настоящую причину, пришедшую на смену прежней.
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
    // Причина у эпизода одна на всё стояние: цели ставит плохой результат пробы,
    // и она же приходит с причиной. Сменить её, пока цели стоят, нечем — «вердикта
    // нет» под паузой не меняет ни фазы, ни причины, ни отсчёта, — поэтому причина
    // и разбор свежести снимаются один раз, при открытии эпизода, и живут до исхода.
    @ObservationIgnored private var pauseEpisodeID: UUID?
    @ObservationIgnored private var pausedEpisodePIDs: Set<Int32> = []
    @ObservationIgnored private var pauseStaleness: VerdictStaleness?
    @ObservationIgnored private var pauseEpisodeReason: String?

    // pid, которым SIGCONT в текущем снятии паузы уже уходил. Цель, стоящая после
    // своего же сигнала, — это ответ, а не ожидание: обязательство держится дальше,
    // но журналу пора сказать, что возобновления не было.
    @ObservationIgnored private var signalledForResume: Set<Int32> = []

    // Сколько раз запись ответила стопом на свой же SIGCONT. Настоящее фоновое задание
    // отвечает так каждый такт, и досылать ему сигнал бесконечно нельзя: `notify` у zsh
    // включён по умолчанию, и терминал печатает `suspended (tty input)` на каждый ответ.
    // Обязательство от этого не исчезает — запись держит учёт, а исполняют её
    // завершение и штатный выход.
    @ObservationIgnored private var stopAnswers: [Int32: Int] = [:]

    // Проход охраны: свой у такта и свой у пришедшего ответа пробы. Разбор снятия
    // паузы зовут оба, и второй SIGCONT в тот же проход был бы лишним шумом.
    @ObservationIgnored private var passID = 0
    @ObservationIgnored private var settledResumePass = -1

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
        // Запись, которую этот проход не разрешил, остаётся в учёте — дальше её ведёт
        // такт охраны через `settleResume()`, — и обязана быть видимой: эпизода паузы
        // в этом запуске нет, и без этого пользователь не узнал бы о стоящей цели ничего.
        let recovered = enforcer.resumeOrphans()
        if !recovered.outcome.unresolved.isEmpty {
            surfaceRecovered(recovered.outcome.unresolved, in: recovered.observed)
        }
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
        // Штатный выход: замороженных целей не оставляем. Наблюдать последствия
        // сигнала здесь уже нечем — такта больше не будет, — поэтому запись, которую
        // SIGCONT не разрешил, остаётся в учёте и достаётся `resumeOrphans` при
        // следующем запуске.
        //
        // Журнал говорит ровно то, что установлено. «Не возобновлено» здесь было бы
        // такой же неправдой, как прежнее «возобновлено»: стоящими записи показал обход,
        // снятый ДО сигнала, — то есть про судьбу самого сигнала не известно ничего,
        // и штатный выход при стоящих целях (самый частый случай) заявлял бы отказ
        // там, где SIGCONT почти всегда срабатывает. Отказ ядра — единственное, что
        // наблюдается и здесь, и он называется как обычно.
        let outcome = enforcer.resume()
        let refused = outcome.results.filter { !$0.isDelivered }.map(\.pid)
        if outcome.isComplete {
            resolvePauseEpisode("возобновлено: охрана остановлена")
        } else if !refused.isEmpty {
            resolvePauseEpisode(unresolvedEpisodeText(standing: outcome.unresolved.map(\.pid),
                                                      refused: refused))
        } else {
            resolvePauseEpisode("не подтверждено: сигнал продолжения отправлен процессам "
                                + "\(outcome.unresolved.map(\.pid)), а охрана остановлена — "
                                + "результат наблюдать нечем, weto проверит их "
                                + "при следующем запуске")
        }
        let stillStanding = Set(outcome.unresolved.map(\.pid))
        pausedProcesses.removeAll { !stillStanding.contains($0.pid) }
        // Фаза обязана уйти вместе с целями: «Пауза», оставленная после остановки,
        // тикала бы отсчётом до потолка, которого никто больше не считает,
        // и `pauseDeadline` показывал бы интерфейсу стояние без стоящих.
        phase = .disabled
    }

    /// Цвет статуса для глаза. Решается по действию над целями (`GuardPhase.action`),
    /// а не по факту летящей пробы: «Проверяю выход» — рабочая фаза, и жёлтый
    /// у неё был бы тревогой без единой улики. Тревожный цвет держат только
    /// стоящая и завершённая фазы; между ними стоит «Помехи»-как-цвет —
    /// та же «На страже» в заголовке, но с доказанно не идеальным ответом,
    /// и щит обязан это показать, раз слово больше не показывает.
    public var statusColor: GuardStatusColor {
        switch phase {
        case .disabled, .verifying:
            // Работают, но про выход ничего не известно — не тревога, а отсутствие
            // данных, тот же серый, что у выключенной охраны.
            return .grey
        case .protected:
            return .green
        case .interference:
            // Работают, но не идеально: адрес доказанно тот же, а не свежий safe.
            return .yellow
        case .paused:
            // Стоят — тревожный цвет держится за паузой, а не за пробой в полёте.
            return .yellow
        case .danger:
            return .red
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
        passID += 1
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

        // Такт без новостей до `apply` не доходит вовсе: `GuardController.emit` глушит
        // его, пока цели работают и фаза не менялась. А обязательство «вернуть из паузы»
        // держится до наблюдения, и цель, вернувшуюся в стоп по SIGTTIN, догоняет
        // именно этот вызов — раз в секунду, пока учёт не опустеет.
        settleResume()
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
        if ownsScan {
            currentScan = enforcer.scan(includingVPNApp: true)
            passID += 1
        }
        defer { if ownsScan { currentScan = nil } }

        self.phase = phase
        lastOrigin = origin

        switch effect {
        case .pause: pauseTargets()
        case .resume:
            // Снятие паузы разбирается ниже, в ветке работающих целей: обязательство
            // держится до наблюдения, и разбирает его каждый проход с работающими
            // целями, а не только тот, что принёс эффект.
            break
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
            // После сброса, а не до: отказ в правах на SIGCONT — сообщение про сигнал,
            // который только что не дошёл, и гасить его тем же проходом нельзя.
            settleResume()
        case .pause, .terminate:
            startWatchdog()
        }
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
    ///
    /// Стоящая фаза ровно одна, и приходит она с готовой причиной: «подключение ещё
    /// не проверено» больше не бывает причиной стояния — до ответа пробы цели работают.
    /// Вызывается только из `pauseTargets()`, а её вызывает только `applyCurrentAction()`
    /// на `phase.action == .pause` — единственная фаза с этим действием и есть `.paused`,
    /// так что вторая ветка недостижима. Она остаётся страховкой, а не источником текста:
    /// заголовок статуса — не причина завершения, и молча вернуть его в журнал вместо
    /// причины паузы было бы неправдой.
    private var pauseReasonText: String {
        guard case .paused(_, let reason) = phase else {
            assertionFailure("pauseReasonText спрошен вне паузы: \(phase)")
            return phase.title
        }
        return reason.displayText
    }

    /// Разбор свежести спрашивается у контроллера ровно в тот миг, когда плохой результат
    /// поставил цели: он взведён на время применения вердикта и сразу гаснет, поэтому
    /// эпизоду достаётся разбор про его собственный момент, а не про давнюю смену пути.
    ///
    /// `nil` тут бывает и по делу: молчание сервисов при неизменном выходе свежести
    /// не теряет, и вердикту нечего было терять. Состояние выхода в этот момент
    /// показания несут отдельными полями.
    private var currentPauseStaleness: VerdictStaleness? {
        if case .paused = phase { return controller.lastStaleness }
        return nil
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

        // Про pid, уже описанный этим эпизодом, второй записи не бывает: остановлен он
        // один раз, и повтора журнал не допускает. А вот эпизод, закрытый исходом,
        // начинается заново — цель, остановленную после него снова, журнал обязан
        // описать, даже если её запись в учёте дожила с прошлой паузы.
        let newcomers = outcome.fresh.filter { !pausedEpisodePIDs.contains($0.pid) }
        guard !newcomers.isEmpty else { return }

        let episodeID = pauseEpisodeID ?? UUID()
        if pauseEpisodeID == nil {
            pauseEpisodeID = episodeID
            pauseEpisodeReason = pauseReasonText
            pauseStaleness = currentPauseStaleness
            // Новое стояние — новое снятие паузы: pid, которым SIGCONT уходил в прошлый
            // раз, не имеют права сойти за «сигнал не прижился» у этого эпизода,
            // а счёт их ответов начинается заново.
            signalledForResume.removeAll()
            stopAnswers.removeAll()
        }
        let moment = now()
        let diagnostics = currentDiagnostics(staleness: pauseStaleness)
        // Причина берётся у эпизода, а не у фазы: новорождённый под паузой обязан
        // встать в один ряд с остальными, а не принести свой текст.
        let reasonText = pauseEpisodeReason ?? pauseReasonText
        eventLog.record(newcomers.map { process in
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
        pausedEpisodePIDs.formUnion(newcomers.map(\.pid))

        for root in newcomers where root.matchedBy == .rule {
            let backgrounded = outcome.plan.backgrounded.contains(root.pid)
            // Пилюля у цели, стоявшей до нового эпизода, уже есть, и признак «вернулось
            // в фон» у неё вернее нашего: его дописало наблюдение, а не догадка плана.
            // А вот момент — наш: эта цель успела поработать между эпизодами (иначе она
            // не попала бы в `fresh` — `pause` пропускает то, что стоит по нашему учёту),
            // значит текущее стояние началось сейчас. Цель, так и не ожившая с прошлого
            // эпизода, момента не меняет: она правда стоит с прошлого раза, и её `since`
            // остаётся верным. На отсчёт в интерфейсе ни то, ни другое не влияет —
            // он читается из фазы редьюсера.
            if let index = pausedProcesses.firstIndex(where: { $0.pid == root.pid }) {
                let survivor = pausedProcesses[index]
                pausedProcesses[index] = PausedProcess(
                    pid: survivor.pid, targetName: survivor.targetName,
                    since: moment, isBackgrounded: survivor.isBackgrounded
                )
                continue
            }
            pausedProcesses.append(PausedProcess(pid: root.pid, targetName: root.targetName,
                                                 since: moment, isBackgrounded: backgrounded))
            if backgrounded { notifier.notifyBackgrounded(targetName: root.targetName) }
        }
    }

    /// Снятие паузы: SIGCONT всем, кто ещё в учёте, и правда о том, что из этого вышло.
    ///
    /// Зовётся не эффектом `.resume`, а каждым проходом с работающими целями, пока учёт
    /// не пуст: обязательство «вернуть из паузы» снимает наблюдение, а не отправка
    /// сигнала. Цель, которую SIGCONT разбудил, а SIGTTIN тут же вернул в стоп, остаётся
    /// в учёте и получает сигнал снова — такт идёт раз в секунду, так что восстановление
    /// автоматическое и перезапуска приложения не требует.
    private func settleResume() {
        guard phase.action == .run, !ledger.entries.isEmpty, settledResumePass != passID else { return }
        settledResumePass = passID

        // Кому SIGCONT уже уходил до этого прохода: только про них можно сказать,
        // что сигнал не прижился. Стоящая цель, сигнал которой ушёл прямо сейчас,
        // ещё не ответила — наблюдение шло по обходу, снятому до отправки.
        let awaited = signalledForResume
        // Кого перестали трогать: ответ получен и повторён, дальше это не попытка
        // возобновления, а строка `suspended (tty input)` в терминале пользователя
        // раз в секунду. Обязательство остаётся — запись не уходит из учёта.
        let abandoned = exhaustedResumePIDs
        let outcome = enforcer.resume(observing: currentScan, skipping: abandoned)
        signalledForResume.formUnion(outcome.results.map(\.pid))
        for pid in outcome.released { stopAnswers[pid] = nil }

        let refused = outcome.results.filter { !$0.isDelivered }.map(\.pid)
        if !refused.isEmpty {
            permissionFailure = "Не удалось возобновить процессы \(refused) — недостаточно прав"
        }

        guard !outcome.isComplete else {
            resolvePauseEpisode(resumedEpisodeText)
            signalledForResume.removeAll()
            stopAnswers.removeAll()
            pausedProcesses.removeAll()
            return
        }

        // Цель, которая всё ещё стоит, возобновлённой выглядеть не имеет права: пилюля
        // остаётся, а признак «вернулась в фон» у неё теперь верен по факту — терминал
        // у шелла, иначе SIGCONT прижился бы.
        let answered = outcome.unresolved.filter { awaited.contains($0.pid) }
        for entry in answered where !abandoned.contains(entry.pid) {
            stopAnswers[entry.pid, default: 0] += 1
        }
        surfaceStanding(outcome.unresolved, answered: Set(answered.map(\.pid)))

        guard !answered.isEmpty || !refused.isEmpty else { return }
        resolvePauseEpisode(unresolvedEpisodeText(standing: outcome.unresolved.map(\.pid), refused: refused))
    }

    /// Записи, которым SIGCONT больше не досылается: ответ «встал обратно» получен
    /// столько раз, сколько разрешает `resumeRetryLimit`. Дальше это не попытка
    /// возобновления, а шум в терминале пользователя. Обязательство держится: запись
    /// остаётся в учёте, и её исполняют завершение по доказательству и штатный выход.
    private var exhaustedResumePIDs: Set<Int32> {
        Set(stopAnswers.filter { $0.value >= Constants.resumeRetryLimit }.map(\.key))
    }

    /// Учёт, доживший до нового запуска: SIGCONT этим записям только что ушёл,
    /// а ответа ядра в этой жизни процесса ещё никто не видел.
    ///
    /// Эпизода паузы в этом запуске нет — журнал завершений про такие записи молчит
    /// по построению, и без этого пользователь не узнал бы о стоящей цели ничего:
    /// ни пилюли, ни подсказки про `fg`, ни следа в журналах. След остаётся там, где
    /// ему место, — в журнале проверок с поводом «восстановление после падения»,
    /// одной записью на восстановление, а не на такт.
    ///
    /// Обход приходит параметром: `resumeOrphans` только что прошёл по всем процессам,
    /// чтобы отличить стоящих от исчезнувших, и второй такой же проход дал бы то же самое
    /// вдвое дороже — а на старте это ещё и другой момент времени.
    private func surfaceRecovered(_ standing: [StoppedProcess], in scan: ProcessEnforcer.Scan) {
        var nameByPID: [Int32: String] = [:]
        for process in ProcessMatcher.matches(in: scan.processes, rules: scan.rules)
        where process.matchedBy == .rule {
            nameByPID[process.pid] = process.targetName
        }
        for entry in standing where !entry.isShell {
            guard let name = nameByPID[entry.pid],
                  !pausedProcesses.contains(where: { $0.pid == entry.pid })
            else { continue }
            // «Вернулось в фон» дописывает первое же наблюдение: сейчас известно только
            // то, что процесс стоял, а стоит ли он после нашего SIGCONT — ответит такт.
            pausedProcesses.append(PausedProcess(pid: entry.pid, targetName: name,
                                                 since: entry.stoppedAt, isBackgrounded: false))
        }
        // Сигнал этим записям уже ушёл, поэтому следующее наблюдение — их ответ,
        // а не ожидание: иначе такт молча слал бы SIGCONT по второму разу.
        signalledForResume.formUnion(standing.map(\.pid))
        checkLog.record(CheckEvent(
            date: now(),
            trigger: .startupRecovery,
            outcome: .standingProcessesRemain,
            fingerprint: snapshotReader.snapshot().verdictFingerprint,
            detail: "учёт остановленных: процессы \(standing.map(\.pid)) стояли на старте — "
                + "продолжение отправлено, дальше их ведёт такт охраны"
        ))
    }

    /// Исход эпизода, у которого возобновление наблюдалось.
    private var resumedEpisodeText: String {
        if case .disabled = phase {
            return "возобновлено: охрана выключена или целей нет"
        }
        // Чтение самой фазы, а не последнее известное: паузу снимает конкретный
        // вердикт, и в исходе обязан стоять его адрес.
        if let reading = phase.reading ?? lastReading {
            return "возобновлено: проверка подтвердила безопасный выход: "
                + "\(reading.ip), \(reading.primaryCountry)"
        }
        return "возобновлено: проверка подтвердила безопасный выход"
    }

    /// Исход эпизода, у которого возобновления не случилось. Журнал обязан говорить
    /// правду: «возобновлено» пишется только про наблюдённое возобновление, иначе
    /// запись выдавала бы замороженную цель за живую.
    private func unresolvedEpisodeText(standing: [Int32], refused: [Int32]) -> String {
        if !refused.isEmpty {
            return "не возобновлено: сигнал продолжения не дошёл до процессов \(refused) — "
                + "недостаточно прав"
        }
        return "не возобновлено: процессы \(standing) остались остановленными — "
            + "задание ушло в фон, продолжите его в терминале командой fg"
    }

    /// Пилюли с подсказкой про `fg` остаются ровно у того, кто действительно стоит.
    /// Цель, ответившая стопом на свой же SIGCONT, помечается фоновой независимо от того,
    /// что про неё думал план паузы: терминал у шелла — это уже наблюдённый факт.
    private func surfaceStanding(_ standing: [StoppedProcess], answered: Set<Int32>) {
        let pids = Set(standing.map(\.pid))
        pausedProcesses.removeAll { !pids.contains($0.pid) }
        for index in pausedProcesses.indices {
            let paused = pausedProcesses[index]
            guard answered.contains(paused.pid), !paused.isBackgrounded else { continue }
            pausedProcesses[index] = PausedProcess(pid: paused.pid, targetName: paused.targetName,
                                                   since: paused.since, isBackgrounded: true)
            notifier.notifyBackgrounded(targetName: paused.targetName)
        }
    }

    /// Исход эпизода паузы: записи те же, к ним дописывается, чем стояние кончилось.
    /// Без исхода запись навсегда остаётся с отговоркой «сервисы не ответили»,
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
    /// только выгрузке. `staleness` называется явно вызывающим: разбор свежести есть
    /// у эпизода паузы и только у него — у завершения по доказательству терять было
    /// нечего, вердикт как раз получен.
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
