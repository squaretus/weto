import Foundation
import WetoCore
import WetoSystem

/// Машина состояний охраны: владеет редьюсером `GuardMachine`, сетевой пробой и свежестью
/// вердикта. Сам он не решает ничего — только готовит входы и отдаёт наружу то, что решил
/// редьюсер.
///
/// Три инварианта:
///
/// 1. **Без доказательства — пауза, не завершение.** Нет вердикта про текущий путь — цели стоят;
///    молчание сервисов при установленном вердикте терпится N проб, потом пауза; потолок паузы —
///    завершение. Переходы считает `GuardMachine`, здесь только входы.
/// 2. **Устаревший результат не возвращает safe.** У каждой пробы своя ревизия и отпечаток на старте;
///    результат применяется, только если оба ещё актуальны.
/// 3. **Свежесть вердикта — только отпечаток выхода.** Правка настроек вердикт не обесценивает:
///    решение пересчитывается по установленному чтению синхронно, без пробы и без паузы.
@MainActor
final class GuardController {

    private let settings: SettingsStore
    private let snapshotReader: NetworkSnapshotReading
    private let geoProbe: GeoProbing
    private let debounceInterval: TimeInterval
    private let now: () -> Date

    /// Статус выбранного VPN-приложения. Приходит снаружи: процессы обходит `GuardVM`.
    private let vpnAppStatus: () -> VPNAppStatus

    /// Фаза, эффект над целями и происхождение показаний (для журнала).
    private let onPhase: (GuardPhase, GuardEffect, VerdictOrigin?) -> Void
    private let onCheck: (CheckEvent) -> Void
    /// `nil` гасит показания: устаревшие адрес и страна на экране читаются как «я всё ещё под VPN».
    private let onReport: (GeoProbeReport?) -> Void

    private(set) var machine: GuardMachine
    private var lastEmittedPhase: GuardPhase?

    /// Ревизия настроек — защита от результата пробы, начатой при старых настройках. Свежесть
    /// вердикта от неё больше не зависит.
    private(set) var revision = 0

    /// Разбор потери свежести — только для той единственной записи журнала, которую эта потеря
    /// и вызвала. Взводится перед объявлением и гасится сразу после него: не погашенный, он
    /// приклеивался бы и к эпизоду таймаута через минуты после того, как вердикт устоялся.
    private(set) var lastStaleness: VerdictStaleness?
    private(set) var lastSnapshot: NetworkSnapshot?

    private var probeTask: Task<Void, Never>?
    private var isProbeInFlight = false
    private var pendingTrigger: CheckEvent.Trigger?

    /// Чтение, на котором стоит последний состоявшийся вердикт, и отпечаток, при котором он получен.
    /// Единственный носитель свежести: совпал отпечаток — вердикт про этот путь есть.
    private var established: EstablishedReading?

    /// Потеря вердикта, уже объявленная редьюсеру. Повтор того же объявления в него не идёт:
    /// у «Проверки» он был бы пустым (редьюсер отбивает одинаковую причину сам), а «Опасно»
    /// по истёкшему потолку он снимал бы каждую секунду — отпечаток-то так и остаётся чужим, —
    /// и обе фазы мигали бы по кругу, начиная отсчёт заново.
    private var announcedLoss: AnnouncedLoss?

    private struct EstablishedReading {
        let reading: GeoReading
        let fingerprint: String
    }

    private struct AnnouncedLoss: Equatable {
        let cause: VerdictStaleness.Cause
        let fingerprint: String
    }

    init(
        settings: SettingsStore,
        snapshotReader: NetworkSnapshotReading,
        geoProbe: GeoProbing,
        debounceInterval: TimeInterval,
        now: @escaping () -> Date = Date.init,
        machine: GuardMachine = GuardMachine(),
        vpnAppStatus: @escaping () -> VPNAppStatus,
        onPhase: @escaping (GuardPhase, GuardEffect, VerdictOrigin?) -> Void,
        onReport: @escaping (GeoProbeReport?) -> Void,
        onCheck: @escaping (CheckEvent) -> Void = { _ in }
    ) {
        self.settings = settings
        self.snapshotReader = snapshotReader
        self.geoProbe = geoProbe
        self.debounceInterval = debounceInterval
        self.now = now
        self.machine = machine
        self.vpnAppStatus = vpnAppStatus
        self.onPhase = onPhase
        self.onReport = onReport
        self.onCheck = onCheck

        // Подписка живёт с момента создания, а не со `start()`: настройка, изменённая
        // до старта охраны, обязана быть учтена в первом же решении.
        settings.onGuardConfigurationChange { [weak self] _ in
            self?.configurationChanged()
        }
    }

    var phase: GuardPhase { machine.phase }

    func remainingPause() -> TimeInterval? { machine.remainingPause(at: now()) }

    func stop() {
        probeTask?.cancel()
        probeTask = nil
        // Иначе повод снятой пробы остался бы «кнопкой» навсегда и блокировал
        // автоматические пробы после следующего старта.
        pendingTrigger = nil
    }

    func awaitPendingProbe() async {
        await probeTask?.value
    }

    /// Такт охраны: локальные основания, свежесть вердикта, потолок паузы.
    func evaluate() {
        evaluate(probeTrigger: .networkChange)
    }

    private func evaluate(probeTrigger: CheckEvent.Trigger) {
        let config = settings.guardConfig
        let snapshot = snapshotReader.snapshot()
        lastSnapshot = snapshot
        let moment = now()

        guard settings.isEnabled, config.hasTargets else {
            announcedLoss = nil
            emit(machine.apply(.disarmed, at: moment), origin: nil)
            probeTask?.cancel()
            probeTask = nil
            return
        }

        let fingerprint = snapshot.verdictFingerprint
        let vpn = vpnAppStatus()
        let hasVerdictForPath = established?.fingerprint == fingerprint

        // Локальное доказательство применяется сразу, до сети: закрытый клиент — завершение.
        if case .kill(let evidence)? = GuardPolicy.decideLocal(
            isEnabled: settings.isEnabled, vpn: vpn, config: config
        ) {
            emit(machine.apply(.evidence(evidence), at: moment), origin: hasVerdictForPath ? .established : nil)
            if !hasVerdictForPath {
                // Экран не должен показывать защиту, которой нет; проба нужна ради показаний.
                onReport(nil)
                startProbe(after: debounceInterval, trigger: probeTrigger)
            }
            return
        }

        guard hasVerdictForPath, let established else {
            // Вердикта про этот путь нет: пауза немедленно, без терпимости, и проба.
            // Потолок считает только `.tick`, поэтому он идёт тем же тактом: без него
            // «Проверка», в которую никто не отвечает, стояла бы вечно.
            announceLoss(fingerprint: fingerprint, at: moment)
            startProbe(after: debounceInterval, trigger: probeTrigger)
            return
        }

        // Вердикт про этот путь есть — прошлая потеря закрыта. Забыть её обязательно:
        // иначе возврат на тот же чужой путь уже не объявлялся бы вовсе.
        announcedLoss = nil

        // VPN-приложение вернулось при действующем вердикте — переоценка без пробы.
        if case .danger(.vpnAppNotRunning) = machine.phase {
            let decision = GuardPolicy.decide(GuardSignals(
                isEnabled: settings.isEnabled, vpn: vpn, geo: .resolved(established.reading), config: config
            ))
            emit(machine.apply(.reassessment(decision, reading: established.reading), at: moment), origin: .established)
        }

        emit(machine.apply(.tick, at: moment), origin: .established)
    }

    /// Объявление потери вердикта: разбор свежести живёт ровно на время объявления,
    /// потолок паузы считается тем же тактом, наружу уходит один эффект.
    private func announceLoss(fingerprint: String, at moment: Date) {
        let staleness = VerdictStaleness(
            previousRevision: established == nil ? nil : revision,
            revision: revision,
            previousFingerprint: established?.fingerprint,
            fingerprint: fingerprint
        )
        let loss = AnnouncedLoss(cause: staleness.cause, fingerprint: fingerprint)

        // Повтор того же объявления редьюсеру не идёт — но только пока цели и так
        // не работают. Работающие цели при отсутствии вердикта про их путь — это утечка,
        // и такое совпадение пары объявляется заново, чем бы оно ни было вызвано.
        if announcedLoss == loss, machine.phase.action != .run {
            // Редьюсеру нечего сказать, но потолок обязан идти.
            emit(machine.apply(.tick, at: moment), origin: nil)
            return
        }
        announcedLoss = loss

        lastStaleness = staleness
        if established != nil { onReport(nil) }
        let lost = machine.apply(.verdictLost(staleness.cause), at: moment)
        let ceiling = machine.apply(.tick, at: moment)
        emit(ceiling == .none ? lost : ceiling, origin: nil)
        lastStaleness = nil
    }

    /// Проверка по кнопке: локальное доказательство применяется сразу, запрос уходит всегда.
    func probeNow() {
        let config = settings.guardConfig
        if settings.isEnabled, config.hasTargets,
           case .kill(let evidence)? = GuardPolicy.decideLocal(
               isEnabled: settings.isEnabled, vpn: vpnAppStatus(), config: config
           ) {
            lastSnapshot = snapshotReader.snapshot()
            emit(machine.apply(.evidence(evidence), at: now()), origin: nil)
        }
        startProbe(after: 0, trigger: .manual)
    }

    /// Расписание гео. Пол между пробами обязателен: таймаут ipinfo равен периоду расписания.
    /// Пока цели стоят, ритм тот же: проба и есть путь из паузы.
    func probeOnSchedule() {
        let config = settings.guardConfig
        guard settings.isEnabled, config.hasTargets, !isProbeInFlight else { return }
        startProbe(after: 0, trigger: .schedule)
    }

    /// Правка настроек: вердикт — знание о сети, от состава целей и списков он не зависит.
    /// Решение пересчитывается по установленному чтению синхронно; пробу требует только смена пути.
    private func configurationChanged() {
        revision += 1
        let config = settings.guardConfig
        guard settings.isEnabled, config.hasTargets else {
            evaluate(probeTrigger: .settingsChange)
            return
        }
        let snapshot = snapshotReader.snapshot()
        guard let established, established.fingerprint == snapshot.verdictFingerprint else {
            evaluate(probeTrigger: .settingsChange)
            return
        }
        lastSnapshot = snapshot
        let decision = GuardPolicy.decide(GuardSignals(
            isEnabled: settings.isEnabled, vpn: vpnAppStatus(), geo: .resolved(established.reading), config: config
        ))
        emit(machine.apply(.reassessment(decision, reading: established.reading), at: now()), origin: .established)
    }

    /// Запрос уходит один и доводится до конца.
    ///
    /// Отменять можно только ожидание в окне коалесценции — ради него `cancel`
    /// здесь и стоит. Отменять сам запрос нельзя: пока вердикт несвеж, каждый такт
    /// заново просит пробу, а такт идёт раз в секунду против пятисекундного таймаута
    /// ipinfo. На медленном канале проба не успевала ответить никогда, вердикт
    /// не приходил вовсе, и кнопка «проверить» не давала ничего.
    private func startProbe(after interval: TimeInterval, trigger: CheckEvent.Trigger) {
        // Отпечаток на момент старта: ответ про прежний путь нельзя применять к новому.
        let expectedFingerprint = snapshotReader.snapshot().verdictFingerprint

        guard !isProbeInFlight else {
            // Записывается только нажатие: автоматические поводы приходят каждый такт,
            // и их пропуски — рабочее состояние, а не событие.
            if trigger == .manual {
                onCheck(CheckEvent(date: now(), trigger: trigger, outcome: .skippedProbeInFlight,
                                   fingerprint: expectedFingerprint))
            }
            return
        }
        // Проба по кнопке не уступает автоматической: пользователь нажал, и его запрос
        // обязан уйти — даже если расписание подошло в зазор между созданием задачи и её запросом.
        if pendingTrigger == .manual, trigger != .manual { return }

        let expected = revision
        pendingTrigger = trigger
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            self?.pendingTrigger = nil

            let started = ContinuousClock.now
            self?.isProbeInFlight = true
            let report = await self?.geoProbe.probe()
            self?.isProbeInFlight = false
            guard let report, !Task.isCancelled else { return }

            let elapsed = ContinuousClock.now - started
            let milliseconds = Int((Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18) * 1000)

            self?.applyLatestNetworkOutcome(report, revision: expected, fingerprint: expectedFingerprint,
                                            trigger: trigger, durationMilliseconds: milliseconds)
        }
    }

    private func applyLatestNetworkOutcome(
        _ report: GeoProbeReport,
        revision expected: Int,
        fingerprint expectedFingerprint: String,
        trigger: CheckEvent.Trigger,
        durationMilliseconds: Int
    ) {
        guard revision == expected else {
            note(report, trigger: trigger, outcome: .discardedSettingsChanged,
                 fingerprint: expectedFingerprint, milliseconds: durationMilliseconds)
            return
        }

        let config = settings.guardConfig
        let snapshot = snapshotReader.snapshot()
        let vpn = vpnAppStatus()
        let fingerprint = snapshot.verdictFingerprint

        // Путь наружу сменился, пока проба летела: её ответ описывает уже не нас.
        guard fingerprint == expectedFingerprint else {
            note(report, trigger: trigger, outcome: .discardedPathChanged,
                 fingerprint: expectedFingerprint, milliseconds: durationMilliseconds)
            return
        }

        note(report, trigger: trigger, outcome: report.outcome.isResolved ? .answered : .failed,
             fingerprint: fingerprint, milliseconds: durationMilliseconds)
        // Отчёт отдаётся и при отказе: попап обязан показать, кто именно молчал.
        onReport(report)

        let geo = admissibleOutcome(of: report, fingerprint: fingerprint)
        if case .resolved(let reading) = geo {
            established = EstablishedReading(reading: reading, fingerprint: fingerprint)
            announcedLoss = nil
        }
        lastSnapshot = snapshot

        guard settings.isEnabled, config.hasTargets else {
            announcedLoss = nil
            emit(machine.apply(.disarmed, at: now()), origin: nil)
            return
        }

        let decision = GuardPolicy.decide(GuardSignals(isEnabled: settings.isEnabled, vpn: vpn, geo: geo, config: config))
        let origin: VerdictOrigin? = geo.isResolved ? .current : (established == nil ? nil : .established)
        emit(machine.apply(.verdict(decision, geo: geo), at: now()), origin: origin)
    }

    /// Запись о состоявшейся пробе: показания и трассы сервисов как есть.
    private func note(_ report: GeoProbeReport, trigger: CheckEvent.Trigger, outcome: CheckEvent.Outcome,
                      fingerprint: String, milliseconds: Int) {
        var reading: GeoReading?
        if case .resolved(let value) = report.outcome { reading = value }
        onCheck(CheckEvent(
            date: now(), trigger: trigger, outcome: outcome, fingerprint: fingerprint,
            durationMilliseconds: milliseconds, ip: report.ip, country: reading?.primaryCountry,
            confirmedCountry: reading?.confirmedCountry, confirmSource: reading?.confirmSource?.rawValue,
            services: report.traces, detail: report.outcome.unavailableDetail
        ))
    }

    /// ipinfo молчит — совпал ли адрес от резервного сервиса с адресом установленного вердикта.
    /// Совпал — `.degraded` (доказательство неизменности); другой — `.addressChanged` (страна не проверена);
    /// адреса нет или отпечаток другой — как есть.
    private func admissibleOutcome(of report: GeoProbeReport, fingerprint: String) -> GeoOutcome {
        let outcome = report.outcome
        guard case .unavailable(let detail) = outcome else { return outcome }
        guard let established, established.fingerprint == fingerprint, let address = report.ip else { return outcome }
        guard address == established.reading.ip else {
            return .addressChanged(observed: address, previous: established.reading)
        }
        return .degraded(previous: established.reading, detail: detail)
    }

    /// Фаза уходит наружу, когда есть эффект, фаза сменилась или цели не работают.
    ///
    /// Такт без новостей при работающих целях экран не трогает. А вот стоящие и завершённые
    /// цели объявляются заново каждый такт: «запуск запрещён» — обязательство про процессы,
    /// которых на прошлом такте ещё не было, и снимать его молчанием нельзя.
    private func emit(_ effect: GuardEffect, origin: VerdictOrigin?) {
        let phase = machine.phase
        guard effect != .none || phase != lastEmittedPhase || phase.action != .run else { return }
        lastEmittedPhase = phase
        onPhase(phase, effect, origin)
    }
}
