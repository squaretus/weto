import Foundation
import WetoCore

public protocol NetworkSnapshotReading: Sendable {
    func snapshot() -> NetworkSnapshot
}

/// Снимок сети — вопрос к ядру: через кого уйдёт вердиктный запрос. Рядом —
/// имена поднятых интерфейсов: по ним терминальная версия судит о выбранном туннеле.
///
/// Раньше здесь разбирались сетевые сервисы из `SCDynamicStore`: список кандидатов
/// в VPN, их активные интерфейсы, владелец маршрута по конфигурации. Всё это ушло
/// вместе с выбором туннеля. `SCDynamicStore` остался только в источнике событий,
/// где он честно отвечает на «сеть изменилась».
public struct NetworkSnapshotReader: NetworkSnapshotReading {

    private let routeProbe: RouteProbing
    private let interfaces: InterfaceListing

    public init(routeProbe: RouteProbing = KernelRouteProbe(), interfaces: InterfaceListing = KernelInterfaceList()) {
        self.routeProbe = routeProbe
        self.interfaces = interfaces
    }

    public func snapshot() -> NetworkSnapshot {
        NetworkSnapshot(
            outgoing: routeProbe.outgoingRoute(),
            upInterfaces: interfaces.raisedInterfaces().map(\.name)
        )
    }
}
