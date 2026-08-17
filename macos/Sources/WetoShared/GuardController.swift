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

    private func beginNetworkVerification(config: GuardConfig, snapshot: NetworkSnapshot) {
        let fingerprint = snapshot.verdictFingerprint(forService: config.vpnServiceID)

        if freshVerdict != Verdict(revision: revision, snapshotFingerprint: fingerprint) {
            onDecision(GuardPolicy.pendingVerification(
                isEnabled: settings.isEnabled,
                config: config
            ))
        }

        startProbe(after: debounceInterval)
    }

    private func startProbe(after interval: TimeInterval) {
        let expected = revision

        probeTask?.cancel()
        probeTask = Task { [weak self] in
            // Окно коалесценции гасит только исходящие запросы: состояние
            // уже переведено в fail-closed выше.
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }

            guard let report = await self?.geoProbe.probe() else { return }
            guard !Task.isCancelled else { return }

            self?.applyLatestNetworkOutcome(report, revision: expected)
        }
    }

    private func applyLatestNetworkOutcome(_ report: GeoProbeReport, revision expected: Int) {
        guard revision == expected else { return }

        let config = settings.guardConfig
        let snapshot = snapshotReader.snapshot()
        let vpn = VPNStatusResolver.status(serviceID: config.vpnServiceID, in: snapshot)

        // Отчёт отдаётся и при отказе: попап обязан показать, кто именно молчал.
        onReport(report)

        record(snapshot: snapshot, serviceID: config.vpnServiceID)
        onDecision(GuardPolicy.decide(GuardSignals(
            isEnabled: settings.isEnabled,
            vpn: vpn,
            geo: report.outcome,
            config: config
        )))
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
