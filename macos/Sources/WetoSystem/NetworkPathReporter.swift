import Foundation
import Network

/// Есть ли у машины путь наружу — самый дешёвый ответ, какой даёт система:
/// состояние уже работающего монитора, без единого запроса в сеть.
public protocol NetworkPathReporting: Sendable {
    var hasPath: Bool { get }
}

public final class NetworkPathReporter: NetworkPathReporting, @unchecked Sendable {

    private let monitor = NWPathMonitor()

    public init() {
        monitor.start(queue: DispatchQueue(label: "com.weto.path"))
    }

    deinit { monitor.cancel() }

    public var hasPath: Bool {
        monitor.currentPath.status == .satisfied
    }
}
