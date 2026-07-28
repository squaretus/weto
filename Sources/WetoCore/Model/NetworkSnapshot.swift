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
}

public struct NetworkSnapshot: Equatable, Sendable {
    public let services: [NetworkServiceSnapshot]

    public let primaryServiceUUID: String?

    public init(services: [NetworkServiceSnapshot], primaryServiceUUID: String?) {
        self.services = services
        self.primaryServiceUUID = primaryServiceUUID
    }

    /// Одинаковые имена не склеиваются: выбор хранится по UUID, и два «Happ» — разные цели.
    public var vpnCandidates: [NetworkServiceSnapshot] {
        services.filter(\.isVPN).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
