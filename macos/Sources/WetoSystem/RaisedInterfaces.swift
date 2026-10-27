import Darwin
import Foundation

/// Поднятый интерфейс: имя и адреса, как их видит ядро.
public struct RaisedInterface: Equatable, Sendable {
    public let name: String
    public let addresses: [String]

    public init(name: String, addresses: [String]) {
        self.name = name
        self.addresses = addresses
    }
}

/// Какие интерфейсы подняты. Отдельной границей: список интерфейсов машины
/// в тесте не подделать, а статус туннеля по нему завершает цели.
public protocol InterfaceListing: Sendable {
    /// Подняты — `IFF_UP` и `IFF_RUNNING` разом: интерфейс, включённый без живой
    /// связи (`wg0` без пира, отключённый кабель), трафик не несёт.
    func raisedInterfaces() -> [RaisedInterface]

    /// Все интерфейсы машины, поднятые и опущенные, — только имена. Нужны
    /// `weto vpn set`: имя существующего интерфейса — это туннель, даже если
    /// `wg0` сейчас опущен.
    func interfaceNames() -> [String]
}

extension InterfaceListing {
    /// Без отдельного знания об опущенных — хотя бы поднятые.
    public func interfaceNames() -> [String] { raisedInterfaces().map(\.name) }
}

/// Список поднятых интерфейсов по `getifaddrs`. Порядок — по имени, чтобы снимок
/// не менялся от того, в каком порядке ядро перечислило записи.
public struct KernelInterfaceList: InterfaceListing {

    public init() {}

    public func raisedInterfaces() -> [RaisedInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        let required = UInt32(IFF_UP | IFF_RUNNING)
        var found: [String: Set<String>] = [:]
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard entry.pointee.ifa_flags & required == required else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            let address = entry.pointee.ifa_addr.flatMap(InterfaceAddresses.text(of:))
            found[name, default: []].formUnion(address.map { [$0] } ?? [])
        }
        return found.keys.sorted().map { RaisedInterface(name: $0, addresses: found[$0, default: []].sorted()) }
    }

    /// `if_nameindex` перечисляет интерфейсы ядра независимо от флагов и адресов.
    public func interfaceNames() -> [String] {
        guard let head = if_nameindex() else { return [] }
        defer { if_freenameindex(head) }
        var names: Set<String> = []
        var cursor = head
        while cursor.pointee.if_index != 0, let name = cursor.pointee.if_name {
            names.insert(String(cString: name))
            cursor = cursor.advanced(by: 1)
        }
        return names.sorted()
    }
}
