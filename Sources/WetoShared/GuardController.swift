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
/// в `verificationPending` и убивал цели при полностью исправном VPN.
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
    private let onReading: (GeoReading) -> Void

    private(set) var revision = 0
    private var freshVerdict: Verdict?
    private var probeTask: Task<Void, Never>?

    init(
        settings: SettingsStore,
        snapshotReader: NetworkSnapshotReading,
        geoProbe: GeoProbing,
        debounceInterval: TimeInterval,
        onDecision: @escaping (GuardDecision) -> Void,
        onReading: @escaping (GeoReading) -> Void
    ) {
        self.settings = settings
        self.snapshotReader = snapshotReader
        self.geoProbe = geoProbe
        self.debounceInterval = debounceInterval
        self.onDecision = onDecision
        self.onReading = onReading

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
            probeTask?.cancel()
            probeTask = nil
            record(snapshot: snapshot)
            onDecision(local)
            return
        }

        beginNetworkVerification(config: config, snapshot: snapshot)
    }

    private func beginNetworkVerification(config: GuardConfig, snapshot: NetworkSnapshot) {
        if freshVerdict != Verdict(revision: revision, snapshotFingerprint: snapshot.fingerprint) {
            onDecision(GuardPolicy.pendingVerification(
                isEnabled: settings.isEnabled,
                config: config
            ))
        }

        let expected = revision
        let interval = debounceInterval

        probeTask?.cancel()
        probeTask = Task { [weak self] in
            // Окно коалесценции гасит только исходящие запросы: состояние
            // уже переведено в fail-closed выше.
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }

            guard let outcome = await self?.geoProbe.probe() else { return }
            guard !Task.isCancelled else { return }

            self?.applyLatestNetworkOutcome(outcome, revision: expected)
        }
    }

    private func applyLatestNetworkOutcome(_ geo: GeoOutcome, revision expected: Int) {
        guard revision == expected else { return }

        let config = settings.guardConfig
        let snapshot = snapshotReader.snapshot()
        let vpn = VPNStatusResolver.status(serviceID: config.vpnServiceID, in: snapshot)

        if case .resolved(let reading) = geo {
            onReading(reading)
        }

        record(snapshot: snapshot)
        onDecision(GuardPolicy.decide(GuardSignals(
            isEnabled: settings.isEnabled,
            vpn: vpn,
            geo: geo,
            config: config
        )))
    }

    private func record(snapshot: NetworkSnapshot) {
        freshVerdict = Verdict(revision: revision, snapshotFingerprint: snapshot.fingerprint)
    }

    private func configurationChanged() {
        revision += 1
        freshVerdict = nil
        evaluate()
    }
}
