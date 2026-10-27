import Foundation
import WetoCore
import WetoDesign
import WetoShared

/// Текстовый вид статуса. Заголовки и тексты фаз — из той же презентации,
/// что у окна (`GuardPhase.title`, `StatusPresentation`): терминал не пересказывает
/// охрану своими словами.
enum StatusText {

    static let notRunning = "Охрана не запущена: weto run или weto service install"

    /// Обычный пользователь рядом с остановленной охраной от root: поднимать её — root.
    static let notRunningSystem = "Охрана не запущена: sudo weto service install"

    /// Подписи выровнены по колонке в десять знаков; длиннее неё только
    /// «Обновление:» — она отделяется одним пробелом, а не обрезается.
    private static func row(_ label: String, _ value: String) -> String {
        let caption = label + ":"
        guard caption.count < 10 else { return caption + " " + value }
        return caption.padding(toLength: 10, withPad: " ", startingAt: 0) + value
    }

    private static let continuation = String(repeating: " ", count: 10)

    static func render(_ status: GuardStatus, now: Date) -> [String] {
        var lines = [row("Охрана", "\(status.phase.title) — \(status.phase.action)")]

        // Улика нужна там, где охрана что-то сделала или не знает ответа; у «На страже»
        // она совпадает со строкой выхода, у выключенной — со строкой целей.
        if !["protected", "disabled"].contains(status.phase.kind) {
            lines.append(row("Причина", status.phase.evidence))
        }
        if let deadline = status.pauseDeadline {
            let remaining = Int(deadline.timeIntervalSince(now).rounded(.up))
            lines.append(row("Пауза", "\(WetoPauseBadge.remainingText(seconds: max(0, remaining))) до завершения; "
                + "возобновятся при подтверждении безопасного выхода"))
        }

        lines.append(contentsOf: readout(reading: status.reading, outgoing: status.outgoing, vpn: status.vpn))
        lines.append(contentsOf: targetLines(status.targets))
        lines.append(row("Таймаут", timeoutText(seconds: status.pauseCeilingSeconds)))
        // Только когда есть что сказать: «обновлений нет» статусу не нужно.
        if let version = status.updateAvailable {
            lines.append(row("Обновление", updateText(version)))
        }
        return lines
    }

    static func updateText(_ version: String) -> String {
        "доступна версия \(version) — sudo weto update"
    }

    /// Показания выхода тремя строками: адрес и страны, носитель трафика, VPN.
    /// Общие у статуса работающей охраны и у разовой проверки.
    static func readout(reading: GuardStatus.Reading?, outgoing: GuardStatus.Outgoing?,
                        vpn: GuardStatus.VPN) -> [String] {
        [
            row("Выход", exitText(reading)),
            row("Трафик", outgoing.map { "\($0.interface) (\($0.address))" } ?? "наружу не выпускает никто"),
            row("VPN", vpnText(vpn)),
        ]
    }

    static func exitText(_ reading: GuardStatus.Reading?) -> String {
        guard let reading else { return "неизвестен" }
        var text = reading.ip
        if let country = reading.country { text += " · \(country)" }
        switch (reading.confirmedCountry, reading.confirmSource) {
        case (let confirmed?, let source?): text += ", подтверждено \(source): \(confirmed)"
        case (let confirmed?, nil): text += ", подтверждено: \(confirmed)"
        default: text += ", подтверждения нет"
        }
        return text
    }

    static func vpnText(_ vpn: GuardStatus.VPN) -> String {
        switch (vpn.kind, vpn.status) {
        case ("tunnel", "carrying"): return "туннель \(vpn.name ?? "") — несёт трафик"
        case ("tunnel", "bypassed"):
            return "туннель \(vpn.name ?? "") — поднят, но трафик идёт мимо, через \(vpn.via ?? "другой интерфейс")"
        case ("tunnel", _): return "туннель \(vpn.name ?? "") — не поднят"
        case ("app", "running"): return "приложение \(vpn.name ?? "") — запущено"
        case ("app", _): return "приложение \(vpn.name ?? "") — не запущено"
        default: return vpnNotChosen
        }
    }

    static let vpnNotChosen = "не задан (охрана работает по гео одной)"

    /// Подсказка для цели, чьё задание шелл увёл в фон, — тем же текстом, что у окна.
    static let backgroundedHint = "процесс вернулся в фон. Откройте терминал и введите fg"

    static let noTargets = "не выбраны — охрана ничего не завершает"

    static func targetLines(_ targets: [GuardStatus.Target]) -> [String] {
        guard !targets.isEmpty else { return [row("Цели", noTargets)] }
        var lines: [String] = []
        for (index, target) in targets.enumerated() {
            let state: String
            if !target.paused.isEmpty {
                state = "на паузе (pid \(pids(target.paused)))"
            } else if !target.running.isEmpty {
                state = "запущено \(target.running.count) (pid \(pids(target.running)))"
            } else {
                state = "не запущено"
            }
            let text = "\(target.name) — \(state)"
            lines.append(index == 0 ? row("Цели", text) : continuation + text)
            if !target.backgrounded.isEmpty {
                lines.append(continuation + "  pid \(pids(target.backgrounded)): \(backgroundedHint)")
            }
        }
        return lines
    }

    private static func pids(_ list: [Int32]) -> String {
        list.map(String.init).joined(separator: ", ")
    }

    static func timeoutText(seconds: Int) -> String {
        "подтверждение ждётся \(PauseCeiling.durationText(TimeInterval(seconds)))"
    }

    /// Сводка настроек — для `status`, когда охрана не запущена. Цели и приложение
    /// названы именами, как в `target list` и на Linux, а не записями.
    @MainActor
    static func settingsSummary(
        _ settings: SettingsStore,
        displayName: (String) -> String = { $0 }
    ) -> [String] {
        let vpn: String
        if let tunnel = settings.vpnTunnel {
            vpn = "туннель \(tunnel)"
        } else if let app = settings.vpnAppRule {
            vpn = "приложение \(displayName(app))"
        } else {
            vpn = vpnNotChosen
        }
        let lists: (GeoListKind) -> String = { kind in
            let entries = settings.entries(of: kind)
            return entries.isEmpty ? "пуст" : entries.joined(separator: ", ")
        }
        return [
            row("VPN", vpn),
            row("Цели", settings.targets.isEmpty ? noTargets : settings.targets.map(displayName).joined(separator: ", ")),
            row("Чёрный", lists(.blocked)),
            row("Белый", lists(.allowed)),
            row("Таймаут", timeoutText(seconds: settings.pauseCeiling.rawValue)),
            row("Токен", settings.ipinfoToken.isEmpty ? "не задан" : "задан"),
        ]
    }
}
