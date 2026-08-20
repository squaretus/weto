import Foundation

public struct NetworkServiceSnapshot: Equatable, Sendable, Identifiable {
    public let uuid: String
    public let name: String

    public let activeInterface: String?

    /// Квалификация с границы системы: сервис объявлен туннелем в конфигурации сети.
    /// Выводить это из имени нельзя — «Happ» или «Wi-Fi» пользователь переименует как угодно.
    public let isVPN: Bool

    public var id: String { uuid }

    public init(uuid: String, name: String, activeInterface: String?, isVPN: Bool) {
        self.uuid = uuid
        self.name = name
        self.activeInterface = activeInterface
        self.isVPN = isVPN
    }

    /// Приставка идентификатора кандидата, у которого сервиса нет вовсе:
    /// клиент поднял туннель сам, и опознать его можно только по интерфейсу.
    public static let interfacePrefix = "interface:"

    /// Кандидат от живого интерфейса, а не от записи в настройках сети.
    ///
    /// Имя показывается как есть (`utun4`): выяснить, какое приложение владеет
    /// туннелем, macOS не даёт, а выдумывать ему название значило бы врать.
    /// На Linux в списке стоят имена интерфейсов по той же причине.
    public static func fromInterface(_ name: String) -> NetworkServiceSnapshot {
        NetworkServiceSnapshot(
            uuid: interfacePrefix + name,
            name: name,
            activeInterface: name,
            isVPN: true
        )
    }

    public var isInterfaceBacked: Bool {
        uuid.hasPrefix(Self.interfacePrefix)
    }
}

/// Кто выпускает трафик наружу, по ответу ядра: имя интерфейса и локальный адрес,
/// который ядро выберет источником. Адрес входит в отпечаток не для красоты —
/// туннель может сохранить имя и сменить адрес, и это смена состояния сети.
public struct OutgoingRoute: Equatable, Sendable {
    public let interface: String
    public let address: String

    public init(interface: String, address: String) {
        self.interface = interface
        self.address = address
    }
}

public struct NetworkSnapshot: Equatable, Sendable {
    public let services: [NetworkServiceSnapshot]

    public let primaryServiceUUID: String?

    /// Кто выпускает трафик наружу — по ответу ядра, а не по конфигурации сети.
    ///
    /// `PrimaryInterface` из `SCDynamicStore` для этого не годится: его считает
    /// `configd`, ранжируя сетевые сервисы, а у туннеля, поднятого мимо
    /// NetworkExtension, сервиса нет вовсе. На живой машине с таким клиентом
    /// там стоял `en0`, пока весь публичный трафик уходил в `utun6`.
    public let outgoing: OutgoingRoute?

    public init(
        services: [NetworkServiceSnapshot],
        primaryServiceUUID: String?,
        outgoing: OutgoingRoute? = nil
    ) {
        self.services = services
        self.primaryServiceUUID = primaryServiceUUID
        self.outgoing = outgoing
    }

    /// Отпечаток снимка: по нему видно, устарел ли прежний сетевой вердикт.
    /// Сравнивать сами снимки на равенство недостаточно дёшево для горячего пути.
    ///
    /// В отпечаток входит ровно то, от чего вердикт зависит: состояние выбранного
    /// сервиса и то, через кого ядро выпускает трафик наружу. Чужие сервисы
    /// и туннели не входят намеренно.
    ///
    /// Локальный адрес исходящего маршрута входит вместе с именем интерфейса:
    /// туннель умеет сохранить имя и сменить адрес, и это смена состояния сети.
    ///
    /// Отпечаток по всему снимку выглядел строже, а на деле подставлял: второй VPN,
    /// живущий рядом, рвёт связь и поднимается сам — состав интерфейсов меняется,
    /// прежний вердикт объявляется протухшим, и цели завершаются с
    /// `verificationPending` при полностью исправном выбранном туннеле.
    public func verdictFingerprint(forService serviceID: String?) -> String {
        let selected = serviceID.flatMap { id in services.first { $0.uuid == id } }

        // Пропавший сервис и невыбранный VPN — разные состояния с разными
        // вердиктами впереди (`vpnDown` против `vpnNotConfigured`), и отпечаток
        // обязан их различать.
        let part = selected.map {
            "\($0.uuid):\($0.activeInterface ?? "-"):\($0.isVPN ? "vpn" : "net")"
        } ?? "selected=\(serviceID ?? "-")"

        return [
            part,
            "primary=\(primaryServiceUUID ?? "-")",
            "out=\(outgoing.map { "\($0.interface)/\($0.address)" } ?? "-")",
        ].joined(separator: "|")
    }

    /// Одинаковые имена не склеиваются: выбор хранится по UUID, и два «Happ» — разные цели.
    public var vpnCandidates: [NetworkServiceSnapshot] {
        services.filter(\.isVPN).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
