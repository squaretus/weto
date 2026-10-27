import Foundation
import WetoCore
import WetoShared

/// Файл статуса работающей охраны — `status.json`. Формат общий с Linux.
///
/// Его пишет `weto run` раз в секунду и на каждую смену фазы, а читают `status`
/// и `check`. Поля, которым нечего сказать, — `null`, а не пропуск: читающему
/// не нужно гадать, забыли поле или ответа нет.
struct GuardStatus: Codable, Equatable {

    static let currentVersion = 1

    /// Сколько файл может не обновляться у живой охраны. Пишется он раз в секунду,
    /// так что десять секунд тишины — это охрана, которой больше нет.
    static let freshness: TimeInterval = 10

    var version: Int = GuardStatus.currentVersion
    var pid: Int32
    var updatedAt: Date
    var lastProbeAt: Date?
    var phase: Phase
    var pauseDeadline: Date?
    var reading: Reading?
    var outgoing: Outgoing?
    var vpn: VPN
    var targets: [Target]
    var pauseCeilingSeconds: Int
    /// Версия новее установленной, найденная работающей охраной, или `null`.
    /// Старый файл без поля читается как «обновления нет».
    var updateAvailable: String? = nil

    private enum CodingKeys: String, CodingKey {
        case version, pid, updatedAt, lastProbeAt, phase, pauseDeadline, reading, outgoing, vpn, targets,
             pauseCeilingSeconds, updateAvailable
    }

    struct Phase: Codable, Equatable {
        /// `disabled | verifying | protected | interference | paused | danger`.
        var kind: String
        var title: String
        var action: String
        var evidence: String
    }

    struct Reading: Codable, Equatable {
        var ip: String
        /// `null`, когда адрес назвал резервный сервис, а страну — никто.
        var country: String?
        var confirmedCountry: String?
        var confirmSource: String?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(ip, forKey: .ip)
            try c.encode(country, forKey: .country)
            try c.encode(confirmedCountry, forKey: .confirmedCountry)
            try c.encode(confirmSource, forKey: .confirmSource)
        }
    }

    struct Outgoing: Codable, Equatable {
        var interface: String
        var address: String
    }

    struct VPN: Codable, Equatable {
        /// `none | app | tunnel`.
        var kind: String
        var name: String?
        /// Приложение: `running | notRunning`; туннель: `carrying | down | bypassed`;
        /// не задан: `notChosen`.
        var status: String
        var via: String?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(kind, forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encode(status, forKey: .status)
            try c.encode(via, forKey: .via)
        }
    }

    struct Target: Codable, Equatable {
        var name: String
        var entry: String
        /// Живые сеансы цели — pid корня каждого. Стоящие сюда не входят.
        var running: [Int32]
        var paused: [Int32]
        /// Стоящие, чьё задание шелл увёл в фон: SIGCONT их не поднимет, нужен `fg`.
        /// Расширение общего формата (так же у Linux): без него `status` не мог бы
        /// подсказать `fg`. Старый файл без поля читается как «таких нет».
        var backgrounded: [Int32] = []

        init(name: String, entry: String, running: [Int32], paused: [Int32], backgrounded: [Int32] = []) {
            self.name = name
            self.entry = entry
            self.running = running
            self.paused = paused
            self.backgrounded = backgrounded
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            entry = try c.decode(String.self, forKey: .entry)
            running = try c.decode([Int32].self, forKey: .running)
            paused = try c.decode([Int32].self, forKey: .paused)
            backgrounded = try c.decodeIfPresent([Int32].self, forKey: .backgrounded) ?? []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(pid, forKey: .pid)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(lastProbeAt, forKey: .lastProbeAt)
        try c.encode(phase, forKey: .phase)
        try c.encode(pauseDeadline, forKey: .pauseDeadline)
        try c.encode(reading, forKey: .reading)
        try c.encode(outgoing, forKey: .outgoing)
        try c.encode(vpn, forKey: .vpn)
        try c.encode(targets, forKey: .targets)
        try c.encode(pauseCeilingSeconds, forKey: .pauseCeilingSeconds)
        try c.encode(updateAvailable, forKey: .updateAvailable)
    }

    init(version: Int = GuardStatus.currentVersion, pid: Int32, updatedAt: Date, lastProbeAt: Date?,
         phase: Phase, pauseDeadline: Date?, reading: Reading?, outgoing: Outgoing?, vpn: VPN,
         targets: [Target], pauseCeilingSeconds: Int, updateAvailable: String? = nil) {
        self.version = version
        self.pid = pid
        self.updatedAt = updatedAt
        self.lastProbeAt = lastProbeAt
        self.phase = phase
        self.pauseDeadline = pauseDeadline
        self.reading = reading
        self.outgoing = outgoing
        self.vpn = vpn
        self.targets = targets
        self.pauseCeilingSeconds = pauseCeilingSeconds
        self.updateAvailable = updateAvailable
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        pid = try c.decode(Int32.self, forKey: .pid)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        lastProbeAt = try c.decodeIfPresent(Date.self, forKey: .lastProbeAt)
        phase = try c.decode(Phase.self, forKey: .phase)
        pauseDeadline = try c.decodeIfPresent(Date.self, forKey: .pauseDeadline)
        reading = try c.decodeIfPresent(Reading.self, forKey: .reading)
        outgoing = try c.decodeIfPresent(Outgoing.self, forKey: .outgoing)
        vpn = try c.decode(VPN.self, forKey: .vpn)
        targets = try c.decode([Target].self, forKey: .targets)
        pauseCeilingSeconds = try c.decode(Int.self, forKey: .pauseCeilingSeconds)
        updateAvailable = try c.decodeIfPresent(String.self, forKey: .updateAvailable)
    }

    // MARK: - Сериализация

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> GuardStatus {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GuardStatus.self, from: data)
    }

    /// Запись атомарная — через временный файл и переименование: `status`
    /// не должен прочитать половину файла. Права — `0644` явно: у системной охраны
    /// umask `077`, а статус обязан читаться без sudo.
    func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let temporary = url.appendingPathExtension("tmp")
        try encoded().write(to: temporary)
        chmod(temporary.path, 0o644)
        guard rename(temporary.path, url.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    /// Файла нет, он испорчен или чужой версии — статуса нет.
    static func read(from url: URL) -> GuardStatus? {
        guard let data = FileManager.default.contents(atPath: url.path),
              let status = try? decode(data), status.version == currentVersion
        else { return nil }
        return status
    }

    /// Охрана жива, если файл свежий и процесс из него жив. Одного файла мало:
    /// упавшая охрана оставляет его на месте, а pid из него могли занять.
    /// Отметка из будущего (часы перевели назад) свежестью считается — иначе
    /// перевод часов «останавливал» бы охрану на глазах у пользователя.
    func isLive(at now: Date, isAlive: (Int32) -> Bool) -> Bool {
        now.timeIntervalSince(updatedAt) <= Self.freshness && isAlive(pid)
    }
}

// MARK: - Сборка из состояния охраны

extension GuardStatus {

    /// Всё, из чего собирается статус. Отдельной структурой, а не чтением `GuardVM`
    /// внутри: сборка проверяется тестом без единой границы системы.
    struct Inputs {
        var pid: Int32
        var now: Date
        var phase: GuardPhase
        var lastReading: GeoReading?
        var lastProbeAt: Date?
        var pauseDeadline: Date?
        var outgoing: OutgoingRoute?
        var vpnAppRule: String?
        /// Имя приложения для статуса — как его называет окно.
        var vpnAppName: String?
        var vpnAppStatus: VPNAppStatus
        var vpnTunnel: String?
        var vpnTunnelStatus: VPNTunnelStatus
        /// Запись цели и её имя — в порядке настроек.
        var targets: [(entry: String, name: String)]
        var runningTargets: [RunningTarget]
        var pausedProcesses: [PausedProcess]
        var pauseCeiling: PauseCeiling
        var updateAvailable: String? = nil
    }

    init(_ inputs: Inputs) {
        let explanation = StatusPresentation.explanation(
            for: inputs.phase,
            remainingPause: inputs.pauseDeadline.map { $0.timeIntervalSince(inputs.now) }
        )
        let known = StatusPresentation.knownReading(for: inputs.phase, reading: inputs.lastReading)

        self.init(
            pid: inputs.pid,
            updatedAt: inputs.now,
            lastProbeAt: inputs.lastProbeAt,
            phase: Phase(
                kind: Self.kind(of: inputs.phase),
                title: inputs.phase.title,
                action: Self.actionText(inputs.phase.action),
                evidence: explanation.evidence
            ),
            pauseDeadline: inputs.pauseDeadline,
            reading: known.map {
                Reading(ip: $0.ip, country: $0.primaryCountry, confirmedCountry: $0.confirmedCountry,
                        confirmSource: $0.confirmSource?.rawValue)
            },
            outgoing: inputs.outgoing.map { Outgoing(interface: $0.interface, address: $0.address) },
            vpn: Self.vpn(inputs),
            targets: inputs.targets.map { target in
                // Стоящие помечены именем цели — так их записывает охрана.
                let standing = inputs.pausedProcesses.filter { $0.targetName == target.name }
                let paused = standing.map(\.pid)
                return Target(
                    name: target.name,
                    entry: target.entry,
                    running: inputs.runningTargets.filter { $0.entry == target.entry }.map(\.pid)
                        .filter { !paused.contains($0) },
                    paused: paused,
                    backgrounded: standing.filter(\.isBackgrounded).map(\.pid)
                )
            },
            pauseCeilingSeconds: inputs.pauseCeiling.rawValue,
            updateAvailable: inputs.updateAvailable
        )
    }

    static func kind(of phase: GuardPhase) -> String {
        switch phase {
        case .disabled: return "disabled"
        case .verifying: return "verifying"
        case .protected: return "protected"
        case .interference: return "interference"
        case .paused: return "paused"
        case .danger: return "danger"
        }
    }

    /// Действие над целями строчными — оно идёт вслед за заголовком через тире.
    static func actionText(_ action: GuardAction) -> String {
        switch action {
        case .run: return "цели работают"
        case .pause: return "цели остановлены"
        case .terminate: return "цели завершены"
        }
    }

    private static func vpn(_ inputs: Inputs) -> VPN {
        vpn(appRule: inputs.vpnAppRule, appName: inputs.vpnAppName, appStatus: inputs.vpnAppStatus,
            tunnel: inputs.vpnTunnel, tunnelStatus: inputs.vpnTunnelStatus)
    }

    /// VPN в статусе: что выбрано и в каком оно состоянии на последнем проходе.
    static func vpn(appRule: String?, appName: String?, appStatus: VPNAppStatus,
                    tunnel: String?, tunnelStatus: VPNTunnelStatus) -> VPN {
        if let tunnel {
            switch tunnelStatus {
            case .carrying: return VPN(kind: "tunnel", name: tunnel, status: "carrying", via: nil)
            case .down, .notChosen: return VPN(kind: "tunnel", name: tunnel, status: "down", via: nil)
            case .bypassed(let via): return VPN(kind: "tunnel", name: tunnel, status: "bypassed", via: via)
            }
        }
        if let app = appRule {
            let running = appStatus == .running
            return VPN(kind: "app", name: appName ?? app, status: running ? "running" : "notRunning", via: nil)
        }
        return VPN(kind: "none", name: nil, status: "notChosen", via: nil)
    }
}
