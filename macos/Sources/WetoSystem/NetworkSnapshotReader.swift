import Foundation
import WetoCore

public protocol NetworkSnapshotReading: Sendable {
    func snapshot() -> NetworkSnapshot
}

/// Снимок сети — один вопрос к ядру: через кого уйдёт вердиктный запрос.
///
/// Раньше здесь разбирались сетевые сервисы из `SCDynamicStore`: список кандидатов
/// в VPN, их активные интерфейсы, владелец маршрута по конфигурации. Всё это ушло
/// вместе с выбором туннеля. `SCDynamicStore` остался только в источнике событий,
/// где он честно отвечает на «сеть изменилась».
public struct NetworkSnapshotReader: NetworkSnapshotReading {

    private let routeProbe: RouteProbing

    public init(routeProbe: RouteProbing = KernelRouteProbe()) {
        self.routeProbe = routeProbe
    }

    public func snapshot() -> NetworkSnapshot {
        NetworkSnapshot(outgoing: routeProbe.outgoingRoute())
    }
}
