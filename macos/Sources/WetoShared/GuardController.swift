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

    private let onDecision: (GuardDecision) -> Void
    /// `nil` гасит показания: устаревшие адрес и страна на экране
    /// читаются как «я всё ещё под VPN», хотя защиты уже нет.
    private let onReport: (GeoProbeReport?) -> Void

    private(set) var revision = 0
    private var freshVerdict: Verdict?
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
        onDecision: @escaping (GuardDecision) -> Void,
        onReport: @escaping (GeoProbeReport?) -> Void
    ) {
        self.settings = settings
        self.snapshotReader = snapshotReader
        self.geoProbe = geoProbe
        self.debounceInterval = debounceInterval
        self.onDecision = onDecision
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
        let vpn = VPNStatusResolver.status(serviceID: config.vpnServiceID, in: snapshot)

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
                snapshotFingerprint: snapshot.verdictFingerprint(forService: config.vpnServiceID)
            )
            let isArmed = settings.isEnabled && !config.targets.isEmpty

            if isStale { onReport(nil) }

            record(snapshot: snapshot, serviceID: config.vpnServiceID)
            onDecision(local)

            // Один запрос на смену состояния сети, и только пока охрана на посту:
            // выключенной охране и охране без целей сеть не нужна вовсе.
            if isArmed && isStale {
                startProbe(after: debounceInterval)
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
        let vpn = VPNStatusResolver.status(serviceID: config.vpnServiceID, in: snapshot)

        // Локальное основание применяем сразу: ответ гео-сервисов не должен
        // ни продлевать целям жизнь, ни задерживать их завершение.
        if let local = GuardPolicy.decideLocal(
            isEnabled: settings.isEnabled,
            vpn: vpn,
            config: config
        ) {
            record(snapshot: snapshot, serviceID: config.vpnServiceID)
            onDecision(local)
        }

        startProbe(after: 0)
    }

    /// Судьба целей решается сетью. Запрос при этом уходит не на каждом такте:
    /// пока и настройки, и путь в сеть те же, решение принимается по уже полученному
    /// чтению, а обновляет его расписание гео. Иначе частота опроса системы и частота
    /// обращений к чужим сервисам — одно и то же число, и учащение первого жжёт лимиты
    /// второго: при такте в 5 секунд это больше полумиллиона запросов в месяц.
    private func beginNetworkVerification(config: GuardConfig, snapshot: NetworkSnapshot) {
        let fingerprint = snapshot.verdictFingerprint(forService: config.vpnServiceID)

        guard freshVerdict != Verdict(revision: revision, snapshotFingerprint: fingerprint) else {
            guard let established, established.fingerprint == fingerprint else { return }
            onDecision(GuardPolicy.decide(GuardSignals(
                isEnabled: settings.isEnabled,
                vpn: VPNStatusResolver.status(serviceID: config.vpnServiceID, in: snapshot),
                geo: .resolved(established.reading),
                config: config
            )))
            return
        }

        onDecision(GuardPolicy.pendingVerification(
            isEnabled: settings.isEnabled,
            config: config
        ))

        startProbe(after: debounceInterval)
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
        startProbe(after: 0)
    }

    private func startProbe(after interval: TimeInterval) {
        let expected = revision

        probeTask?.cancel()
        probeTask = Task { [weak self] in
            // Окно коалесценции гасит только исходящие запросы: состояние
            // уже переведено в fail-closed выше.
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }

            self?.isProbeInFlight = true
            let report = await self?.geoProbe.probe()
            self?.isProbeInFlight = false

            guard let report, !Task.isCancelled else { return }

            self?.applyLatestNetworkOutcome(report, revision: expected)
        }
    }

    private func applyLatestNetworkOutcome(_ report: GeoProbeReport, revision expected: Int) {
        guard revision == expected else { return }

        let config = settings.guardConfig
        let snapshot = snapshotReader.snapshot()
        let vpn = VPNStatusResolver.status(serviceID: config.vpnServiceID, in: snapshot)
        let fingerprint = snapshot.verdictFingerprint(forService: config.vpnServiceID)

        // Отчёт отдаётся и при отказе: попап обязан показать, кто именно молчал.
        onReport(report)

        let geo = admissibleOutcome(of: report, fingerprint: fingerprint)
        if case .resolved(let reading) = geo {
            established = EstablishedReading(reading: reading, fingerprint: fingerprint)
        }

        record(snapshot: snapshot, serviceID: config.vpnServiceID)
        onDecision(GuardPolicy.decide(GuardSignals(
            isEnabled: settings.isEnabled,
            vpn: vpn,
            geo: geo,
            config: config
        )))
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

    private func record(snapshot: NetworkSnapshot, serviceID: String?) {
        freshVerdict = Verdict(
            revision: revision,
            snapshotFingerprint: snapshot.verdictFingerprint(forService: serviceID)
        )
    }

    private func configurationChanged() {
        revision += 1
        freshVerdict = nil
        evaluate()
    }
}
