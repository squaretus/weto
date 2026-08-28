import Foundation
import WetoCore
import WetoSystem

/// Машина состояний охраны: решает, что применить, и владеет сетевой пробой.
///
/// Два инварианта, ради которых он вынесен из `GuardVM`:
///
/// 1. **Fail-closed на время проверки.** Как только прежний вердикт перестал быть свежим
///    (холодный старт, смена сетевого пути, правка настроек), цели завершаются немедленно —
///    ещё до запроса к ipinfo. Раньше состояние просто не менялось все секунды ожидания.
/// 2. **Устаревший результат не возвращает safe.** У каждой пробы своя ревизия; результат
///    применяется, только если ревизия ещё актуальна, а решение принимается по настройкам
///    и снимку сети, прочитанным непосредственно перед применением.
///
/// Свежесть вердикта считается по паре «ревизия конфигурации + отпечаток снимка сети».
/// Без этого штатный тик поллинга каждые несколько секунд заново уходил бы
/// в `verificationPending` и убивал цели при полностью исправном VPN. Отпечаток
/// берётся по выбранному сервису (`verdictFingerprint`), а не по всей сети: иначе
/// чужой VPN, переподключившийся сам по себе, стоил бы пользователю целей.
@MainActor
final class GuardController {

    private struct Verdict: Equatable {
        let revision: Int
        let snapshotFingerprint: String
    }

    private let settings: SettingsStore
    private let snapshotReader: NetworkSnapshotReading
    private let geoProbe: GeoProbing
    private let debounceInterval: TimeInterval

    /// Статус выбранного VPN-приложения. Приходит снаружи: процессы обходит
    /// `GuardVM` — у него уже есть скан, и второй обход был бы лишним.
    private let vpnAppStatus: () -> VPNAppStatus

    private let onDecision: (GuardDecision) -> Void

    /// Каждая попытка проверки — включая ту, где запрос так и не ушёл.
    /// Журнал завершений про это молчит: нажатие, не породившее завершения,
    /// следа не оставляет.
    private let onCheck: (CheckEvent) -> Void
    /// `nil` гасит показания: устаревшие адрес и страна на экране
    /// читаются как «я всё ещё под VPN», хотя защиты уже нет.
    private let onReport: (GeoProbeReport?) -> Void

    private(set) var revision = 0
    private var freshVerdict: Verdict?

    /// Почему вердикт перестал быть свежим в последний раз и через кого машина
    /// выходила наружу. Journal читает это, записывая эпизод: без такой пары
    /// «подключение ещё не проверено» не отличить от «изменили настройки».
    private(set) var lastStaleness: VerdictStaleness?
    private(set) var lastSnapshot: NetworkSnapshot?

    /// Последний состоявшийся вердикт. В отличие от `freshVerdict` не обнуляется
    /// правкой настроек: обнулённый, он делал изменение настроек неотличимым
    /// от холодного старта, а в журнале это два разных ответа на вопрос
    /// «почему цели завершились».
    private var previousVerdict: Verdict?
    private var probeTask: Task<Void, Never>?
    private var isProbeInFlight = false

    /// Чтение, на котором стоит последний состоявшийся вердикт, и отпечаток сети,
    /// при котором он получен. Нужно, чтобы молчание ipinfo не завершало цели,
    /// когда адрес доказанно тот же: тот же адрес — та же страна.
    private var established: EstablishedReading?

    private struct EstablishedReading {
        let reading: GeoReading
        let fingerprint: String
    }

    init(
        settings: SettingsStore,
        snapshotReader: NetworkSnapshotReading,
        geoProbe: GeoProbing,
        debounceInterval: TimeInterval,
        vpnAppStatus: @escaping () -> VPNAppStatus,
        onDecision: @escaping (GuardDecision) -> Void,
        onReport: @escaping (GeoProbeReport?) -> Void,
        onCheck: @escaping (CheckEvent) -> Void = { _ in }
    ) {
        self.settings = settings
        self.snapshotReader = snapshotReader
        self.geoProbe = geoProbe
        self.debounceInterval = debounceInterval
        self.vpnAppStatus = vpnAppStatus
        self.onDecision = onDecision
        self.onCheck = onCheck
        self.onReport = onReport

        // Подписка живёт с момента создания, а не со `start()`: настройка, изменённая
        // до старта охраны, обязана быть учтена в первом же решении.
        settings.onGuardConfigurationChange { [weak self] _ in
            self?.configurationChanged()
        }
    }

    func stop() {
        probeTask?.cancel()
        probeTask = nil
    }

    func awaitPendingProbe() async {
        await probeTask?.value
    }

    /// Полный цикл решения: локальные основания, затем — при необходимости — сеть.
    func evaluate() {
        let config = settings.guardConfig
        let snapshot = snapshotReader.snapshot()
        let vpn = vpnAppStatus()

        if let local = GuardPolicy.decideLocal(
            isEnabled: settings.isEnabled,
            vpn: vpn,
            config: config
        ) {
            // Экономия запросов относится к вердикту, а не к экрану. Пока её
            // распространяли и на показания, после падения VPN там навсегда
            // оставались адрес и страна туннеля — то есть экран показывал
            // защиту, которой уже нет.
            let isStale = freshVerdict != Verdict(
                revision: revision,
                snapshotFingerprint: snapshot.verdictFingerprint
            )
            let isArmed = settings.isEnabled && !config.targets.isEmpty

            if isStale { onReport(nil) }

            record(snapshot: snapshot)
            onDecision(local)

            // Один запрос на смену состояния сети, и только пока охрана на посту:
            // выключенной охране и охране без целей сеть не нужна вовсе.
            if isArmed && isStale {
                startProbe(after: debounceInterval, trigger: stalenessTrigger(for: snapshot))
            } else {
                probeTask?.cancel()
                probeTask = nil
            }
            return
        }

        beginNetworkVerification(config: config, snapshot: snapshot)
    }

    /// Проверка по требованию пользователя: запрос уходит немедленно и не объявляет
    /// прежний вердикт протухшим. Иначе кнопка «проверить сейчас» означала бы
    /// завершение целей при полностью исправном VPN.
    ///
    /// В сеть идём **всегда**, даже когда судьба целей решается локально — при
    /// выключенном VPN, невыбранном сервисе или выключенной охране. Экономия
    /// запросов имеет смысл на штатном тике, а кнопка отвечает на другой вопрос:
    /// «где я сейчас». Раньше локальное основание закрывало этот путь, и попап
    /// молчал о стране ровно тогда, когда пользователь и хотел её увидеть.
    func probeNow() {
        let config = settings.guardConfig
        let snapshot = snapshotReader.snapshot()
        let vpn = vpnAppStatus()

        // Локальное основание применяем сразу: ответ гео-сервисов не должен
        // ни продлевать целям жизнь, ни задерживать их завершение.
        if let local = GuardPolicy.decideLocal(
            isEnabled: settings.isEnabled,
            vpn: vpn,
            config: config
        ) {
            record(snapshot: snapshot)
            onDecision(local)
        }

        startProbe(after: 0, trigger: .manual)
    }

    /// Судьба целей решается сетью. Запрос при этом уходит не на каждом такте:
    /// пока и настройки, и путь в сеть те же, решение принимается по уже полученному
    /// чтению, а обновляет его расписание гео. Иначе частота опроса системы и частота
    /// обращений к чужим сервисам — одно и то же число, и учащение первого жжёт лимиты
    /// второго: при такте в 5 секунд это больше полумиллиона запросов в месяц.
    private func beginNetworkVerification(config: GuardConfig, snapshot: NetworkSnapshot) {
        let fingerprint = snapshot.verdictFingerprint
        lastSnapshot = snapshot

        guard freshVerdict != Verdict(revision: revision, snapshotFingerprint: fingerprint) else {
            guard let established, established.fingerprint == fingerprint else { return }
            onDecision(GuardPolicy.decide(GuardSignals(
                isEnabled: settings.isEnabled,
                vpn: vpnAppStatus(),
                geo: .resolved(established.reading),
                config: config
            )))
            return
        }

        lastStaleness = VerdictStaleness(
            previousRevision: previousVerdict?.revision,
            revision: revision,
            previousFingerprint: previousVerdict?.snapshotFingerprint,
            fingerprint: fingerprint
        )

        onDecision(GuardPolicy.pendingVerification(
            isEnabled: settings.isEnabled,
            config: config
        ))

        startProbe(after: debounceInterval, trigger: stalenessTrigger(for: snapshot))
    }

    /// Повод пробы выводится из того, что именно перестало быть свежим: ревизия
    /// настроек или отпечаток выхода. Отдельного канала для этого не нужно —
    /// обе величины у контроллера и так под рукой.
    private func stalenessTrigger(for snapshot: NetworkSnapshot) -> CheckEvent.Trigger {
        guard let previousVerdict else { return .networkChange }
        return previousVerdict.revision != revision ? .settingsChange : .networkChange
    }

    /// Запрос по расписанию: страна выхода меняется и на неизменном пути — например,
    /// когда пользователь переключает сервер внутри своего клиента, — и отпечаток
    /// об этом не скажет.
    ///
    /// Пол между пробами обязателен: таймаут ipinfo равен периоду расписания,
    /// и без него пробы начнут накладываться.
    func probeOnSchedule() {
        let config = settings.guardConfig
        guard settings.isEnabled, config.hasTargets, !isProbeInFlight else { return }
        startProbe(after: 0, trigger: .schedule)
    }

    /// Запрос уходит один и доводится до конца.
    ///
    /// Отменять можно только ожидание в окне коалесценции — ради него `cancel`
    /// здесь и стоит. Отменять сам запрос нельзя: пока вердикт несвеж, каждый такт
    /// заново объявляет fail-closed и просит пробу, а такт идёт раз в секунду
    /// против пятисекундного таймаута ipinfo. На медленном канале — например, сразу
    /// после подъёма второго VPN — проба не успевала ответить никогда, вердикт
    /// не приходил вовсе, и кнопка «проверить» не давала ничего.
    private func startProbe(after interval: TimeInterval, trigger: CheckEvent.Trigger) {
        // Отпечаток на момент старта: ответ про прежний путь нельзя применять
        // к новому. Раньше от этого спасала отмена — теперь спасать должно явно.
        let expectedFingerprint = snapshotReader.snapshot().verdictFingerprint

        guard !isProbeInFlight else {
            // Записывается только нажатие: «нажал пять раз, а запрос так и не ушёл»
            // объяснить нечем иначе. Автоматические поводы приходят каждый такт,
            // и их пропуски — нормальное состояние, а не событие: за пять секунд
            // ожидания ipinfo они вытеснили бы из полусотни записей ровно ту одну,
            // ради которой журнал и ведётся.
            if trigger == .manual {
                onCheck(CheckEvent(
                    date: Date(),
                    trigger: trigger,
                    outcome: .skippedProbeInFlight,
                    fingerprint: expectedFingerprint
                ))
            }
            return
        }

        let expected = revision

        probeTask?.cancel()
        probeTask = Task { [weak self] in
            // Окно коалесценции гасит только исходящие запросы: состояние
            // уже переведено в fail-closed выше.
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }

            let started = ContinuousClock.now
            self?.isProbeInFlight = true
            let report = await self?.geoProbe.probe()
            self?.isProbeInFlight = false

            // Отмена бывает ровно одна: `stop()` при завершении работы. Проба,
            // вытесняемая другой, здесь больше не появляется — но применить ответ
            // после остановки охраны значило бы заново поднять сторожевой таймер
            // у выключённого приложения.
            guard let report, !Task.isCancelled else { return }

            let elapsed = ContinuousClock.now - started
            let milliseconds = Int(
                (Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18) * 1000
            )

            self?.applyLatestNetworkOutcome(
                report,
                revision: expected,
                fingerprint: expectedFingerprint,
                trigger: trigger,
                durationMilliseconds: milliseconds
            )
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

        // Путь наружу сменился, пока проба летела: её ответ описывает уже не нас,
        // и объявлять по нему вердикт значит открыть цели на чужих показаниях.
        // Следующий такт запросит пробу заново — теперь ему есть чем.
        guard fingerprint == expectedFingerprint else {
            note(report, trigger: trigger, outcome: .discardedPathChanged,
                 fingerprint: expectedFingerprint, milliseconds: durationMilliseconds)
            return
        }

        note(
            report,
            trigger: trigger,
            outcome: report.outcome.isResolved ? .answered : .failed,
            fingerprint: fingerprint,
            milliseconds: durationMilliseconds
        )

        // Отчёт отдаётся и при отказе: попап обязан показать, кто именно молчал.
        onReport(report)

        let geo = admissibleOutcome(of: report, fingerprint: fingerprint)
        if case .resolved(let reading) = geo {
            established = EstablishedReading(reading: reading, fingerprint: fingerprint)
        }

        record(snapshot: snapshot)
        onDecision(GuardPolicy.decide(GuardSignals(
            isEnabled: settings.isEnabled,
            vpn: vpn,
            geo: geo,
            config: config
        )))
    }

    /// Запись о состоявшейся пробе: показания и трассы сервисов как есть.
    private func note(
        _ report: GeoProbeReport,
        trigger: CheckEvent.Trigger,
        outcome: CheckEvent.Outcome,
        fingerprint: String,
        milliseconds: Int
    ) {
        var reading: GeoReading?
        if case .resolved(let value) = report.outcome { reading = value }

        onCheck(CheckEvent(
            date: Date(),
            trigger: trigger,
            outcome: outcome,
            fingerprint: fingerprint,
            durationMilliseconds: milliseconds,
            ip: report.ip,
            country: reading?.primaryCountry,
            confirmedCountry: reading?.confirmedCountry,
            confirmSource: reading?.confirmSource?.rawValue,
            services: report.traces,
            detail: report.outcome.unavailableDetail
        ))
    }

    /// Что из отчёта годится в основание вердикта.
    ///
    /// ipinfo ответил — берём его ответ, тут решать нечего. ipinfo молчит — смотрим,
    /// назвал ли резервный сервис наш адрес: совпал с адресом прошлого вердикта, значит
    /// страна та же и перепроверять нечего. Снисхождение выдаётся за доказательство,
    /// а не за давность, и каждый круг доказывается заново: перестанет отвечать
    /// и резервный — адреса не будет, и цели завершатся.
    ///
    /// Сменился отпечаток сети — снисхождения нет ни при каком совпадении адреса:
    /// вердикт при смене пути недействителен по построению.
    private func admissibleOutcome(
        of report: GeoProbeReport,
        fingerprint: String
    ) -> GeoOutcome {
        let outcome = report.outcome
        guard case .unavailable(let detail) = outcome else { return outcome }

        guard let established, established.fingerprint == fingerprint, let address = report.ip
        else { return outcome }

        guard address == established.reading.ip else {
            return .unavailable("адрес сменился, страна не проверена")
        }
        return .degraded(previous: established.reading, detail: detail)
    }

    private func record(snapshot: NetworkSnapshot) {
        lastSnapshot = snapshot
        let verdict = Verdict(revision: revision, snapshotFingerprint: snapshot.verdictFingerprint)
        freshVerdict = verdict
        previousVerdict = verdict
    }

    private func configurationChanged() {
        revision += 1
        freshVerdict = nil
        evaluate()
    }
}
