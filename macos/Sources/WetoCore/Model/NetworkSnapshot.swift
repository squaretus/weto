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

public struct NetworkSnapshot: Equatable, Sendable {
    public let services: [NetworkServiceSnapshot]

    public let primaryServiceUUID: String?

    /// Интерфейс, которому досталась маршрутизация по умолчанию.
    ///
    /// Спрашивается отдельно от сервиса: у туннеля, поднятого в пользовательском
    /// пространстве, сервиса нет, и владельца маршрута по нему не определить.
    public let primaryInterface: String?

    public init(
        services: [NetworkServiceSnapshot],
        primaryServiceUUID: String?,
        primaryInterface: String? = nil
    ) {
        self.services = services
        self.primaryServiceUUID = primaryServiceUUID
        self.primaryInterface = primaryInterface
    }

    /// Отпечаток снимка: меняется, как только меняется состав сервисов, их активность,
    /// квалификация или владелец маршрута по умолчанию. По нему видно, устарел ли
    /// прежний сетевой вердикт, — сравнивать сами снимки на равенство недостаточно
    /// дёшево для горячего пути.
    public var fingerprint: String {
        let parts = services
            .sorted { $0.uuid < $1.uuid }
            .map { "\($0.uuid):\($0.activeInterface ?? "-"):\($0.isVPN ? "vpn" : "net")" }
        return (parts + [
            "primary=\(primaryServiceUUID ?? "-")",
            "iface=\(primaryInterface ?? "-")",
        ]).joined(separator: "|")
    }

    /// Одинаковые имена не склеиваются: выбор хранится по UUID, и два «Happ» — разные цели.
    public var vpnCandidates: [NetworkServiceSnapshot] {
        services.filter(\.isVPN).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
