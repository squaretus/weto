import Foundation

/// Один сетевой сервис macOS в том виде, в каком его отдаёт SCDynamicStore.
///
/// `name` — это `UserDefinedName` из `Setup:/Network/Service/<uuid>`. Опора на имя,
/// а не на интерфейс, принципиальна: номера `utunN` плавают между перезагрузками,
/// а имя стабильно и понятно пользователю.
public struct NetworkServiceSnapshot: Equatable, Sendable {
    public let uuid: String
    public let name: String
    /// Интерфейс из `State:/Network/Service/<uuid>/IPv4`.
    /// `nil` означает, что ключа нет, то есть адреса на сервисе нет и туннель не поднят.
    public let activeInterface: String?

    public init(uuid: String, name: String, activeInterface: String?) {
        self.uuid = uuid
        self.name = name
        self.activeInterface = activeInterface
    }
}

/// Полный снимок сетевой конфигурации на момент опроса.
public struct NetworkSnapshot: Equatable, Sendable {
    public let services: [NetworkServiceSnapshot]
    /// `PrimaryService` из `State:/Network/Global/IPv4` — кто держит default route.
    public let primaryServiceUUID: String?

    public init(services: [NetworkServiceSnapshot], primaryServiceUUID: String?) {
        self.services = services
        self.primaryServiceUUID = primaryServiceUUID
    }

    /// Имена сервисов для выпадающего списка в настройках.
    ///
    /// Сортировка человеческая, а не по скалярам Unicode: иначе `iPhone`
    /// с маленькой буквы уезжает в конец списка после всех заглавных.
    public var vpnCandidateNames: [String] {
        Array(Set(services.map(\.name)))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
