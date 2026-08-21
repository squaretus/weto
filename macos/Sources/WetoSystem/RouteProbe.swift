import Foundation
import WetoCore

/// Через кого ядро выпустит трафик наружу — вопрос к ядру, а не к конфигурации сети.
///
/// Отдельной границей потому, что подделать таблицу маршрутов в тесте нельзя,
/// а проверить остальную сборку снимка нужно. Всё остальное в снимке — чтение
/// живых интерфейсов, и оно врать не умеет.
public protocol RouteProbing: Sendable {
    func outgoingRoute() -> OutgoingRoute?
}

/// Адреса интерфейсов, как их видит ядро.
///
/// `SCDynamicStore` о туннеле, поднятом в пользовательском пространстве, не знает
/// вовсе: у такого туннеля нет сетевого сервиса. `getifaddrs` перечисляет то,
/// что есть на самом деле.
public enum InterfaceAddresses {

    public static func all() -> [String: Set<String>] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }

        var found: [String: Set<String>] = [:]
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: entry.pointee.ifa_name)
            guard let address = entry.pointee.ifa_addr.flatMap(text(of:)) else {
                found[name] = found[name] ?? []
                continue
            }
            found[name, default: []].insert(address)
        }
        return found
    }

    /// Кому принадлежит адрес. Ядро выдаёт исходящий адрес, а нам нужно имя
    /// интерфейса: именно оно попадает в отпечаток и в объяснение на экране.
    public static func owner(of address: String) -> String? {
        all().first { $0.value.contains(address) }?.key
    }

    static func text(of address: UnsafeMutablePointer<sockaddr>) -> String? {
        var storage = [CChar](repeating: 0, count: Int(NI_MAXHOST))

        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            var sin = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            guard inet_ntop(AF_INET, &sin.sin_addr, &storage, socklen_t(INET_ADDRSTRLEN)) != nil
            else { return nil }
        case AF_INET6:
            var sin6 = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
            guard inet_ntop(AF_INET6, &sin6.sin6_addr, &storage, socklen_t(INET6_ADDRSTRLEN)) != nil
            else { return nil }
        default:
            return nil
        }
        return String(cString: storage)
    }
}

/// Спрашивает ядро, каким интерфейсом оно выпустит вердиктный запрос.
///
/// # Почему не дамп маршрутов и не `SCDynamicStore`
///
/// `State:/Network/Global/IPv4` пишет `configd`, ранжируя **сетевые сервисы**.
/// У туннеля, поднятого мимо NetworkExtension, сервиса нет вовсе, и назвать его
/// там нечем: `PrimaryInterface` показывает подлежащий Wi-Fi, хотя весь публичный
/// трафик уже уходит в туннель. Проверено на живой машине: `PrimaryInterface: en0`
/// при рабочем `utun6`.
///
/// Дамп маршрута по умолчанию тоже не годится. Клиент может не забирать
/// маршрут по умолчанию вовсе, а раскладывать маршруты префиксами: там же
/// `route get default → en0`, `route get 8.8.8.8 → utun6`.
///
/// Поэтому спрашиваем ядро: UDP-сокет, `connect` и `getsockname`. `connect` для UDP
/// не отправляет ни байта — он лишь заставляет ядро выполнить полный поиск маршрута
/// и вернуть выбранный локальный адрес.
///
/// # Почему адрес назначения — хост ipinfo
///
/// Фиксированный публичный адрес не годится: клиенты исключают отдельные адреса
/// из туннеля. На машине владельца `1.1.1.1` уведён в `en0` явным маршрутом,
/// и проба по нему объявила бы исправный туннель нерабочим. Спрашивать надо про тот
/// адрес, до которого реально пойдёт вердиктный запрос.
public final class KernelRouteProbe: RouteProbing, @unchecked Sendable {

    /// Как часто разрешать имя заново, пока адреса нет. Разрешение имени идёт
    /// в стороне от опроса охраны и никогда его не блокирует: снимок снимается
    /// каждую секунду, а DNS умеет отвечать секундами.
    private static let resolveRetryInterval: TimeInterval = 30

    private let host: String
    private let queue = DispatchQueue(label: "com.weto.route-probe")
    private let lock = NSLock()

    private var destination: String?
    private var lastAttempt: Date?
    private var isResolving = false

    public init(host: String = Constants.ipinfoHost) {
        self.host = host
        resolveIfNeeded()
    }

    /// Адрес, до которого сейчас идёт проба. Нужен тестам и передаче между пробами.
    public var knownDestination: String? {
        lock.lock(); defer { lock.unlock() }
        return destination
    }

    @discardableResult
    public func withKnownDestination(_ address: String?) -> KernelRouteProbe {
        lock.lock()
        destination = address
        lock.unlock()
        return self
    }

    public func outgoingRoute() -> OutgoingRoute? {
        guard let destination = knownDestination else {
            resolveIfNeeded()
            return nil
        }

        if let route = outgoingRoute(to: destination) { return route }

        // Адрес перестал маршрутизироваться: либо машина офлайн, либо у хоста
        // сменился адрес. Разрешаем имя заново, но не блокируя опрос.
        resolveIfNeeded()
        return nil
    }

    func outgoingRoute(to destination: String) -> OutgoingRoute? {
        guard let address = localAddress(reaching: destination),
              let interface = InterfaceAddresses.owner(of: address)
        else { return nil }
        return OutgoingRoute(interface: interface, address: address)
    }

    /// Локальный адрес, который ядро выберет для этого назначения.
    private func localAddress(reaching destination: String) -> String? {
        var v4 = in_addr()
        var v6 = in6_addr()

        if inet_pton(AF_INET, destination, &v4) == 1 {
            var target = sockaddr_in()
            target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            target.sin_family = sa_family_t(AF_INET)
            target.sin_port = in_port_t(53).bigEndian
            target.sin_addr = v4
            let length = socklen_t(target.sin_len)
            return withUnsafePointer(to: &target) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    localAddress(family: AF_INET, target: $0, length: length)
                }
            }
        }

        if inet_pton(AF_INET6, destination, &v6) == 1 {
            var target = sockaddr_in6()
            target.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            target.sin6_family = sa_family_t(AF_INET6)
            target.sin6_port = in_port_t(53).bigEndian
            target.sin6_addr = v6
            let length = socklen_t(target.sin6_len)
            return withUnsafePointer(to: &target) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    localAddress(family: AF_INET6, target: $0, length: length)
                }
            }
        }

        return nil
    }

    private func localAddress(
        family: Int32,
        target: UnsafePointer<sockaddr>,
        length: socklen_t
    ) -> String? {
        let descriptor = socket(family, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        guard connect(descriptor, target, length) == 0 else { return nil }

        var storage = sockaddr_storage()
        var size = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &size)
            }
        }
        guard named == 0 else { return nil }

        return withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                InterfaceAddresses.text(of: $0)
            }
        }
    }

    private func resolveIfNeeded() {
        lock.lock()
        let due = lastAttempt.map { Date().timeIntervalSince($0) >= Self.resolveRetryInterval } ?? true
        guard !isResolving, due else {
            lock.unlock()
            return
        }
        isResolving = true
        lastAttempt = Date()
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let resolved = Self.resolve(self.host)
            self.lock.lock()
            if let resolved { self.destination = resolved }
            self.isResolving = false
            self.lock.unlock()
        }
    }

    /// Имя в адрес. Предпочитаем IPv4: у ipinfo для вердикта используется
    /// именно `v4.api.ipinfo.io`.
    private static func resolve(_ host: String) -> String? {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_DGRAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }

        var fallback: String?
        for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let address = entry.pointee.ai_addr.flatMap(InterfaceAddresses.text(of:))
            else { continue }
            if entry.pointee.ai_family == AF_INET { return address }
            fallback = fallback ?? address
        }
        return fallback
    }
}
