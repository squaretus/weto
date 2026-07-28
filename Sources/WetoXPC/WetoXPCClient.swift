import Foundation

/// Клиент привилегированного демона. Соединение поднимается лениво и
/// переустанавливается после разрыва: демон умирает при установке обновления,
/// потому что установщик его выгружает.
public final class WetoXPCClient: @unchecked Sendable {

    private let lock = NSLock()
    private var connection: NSXPCConnection?

    public init() {}

    deinit {
        connection?.invalidate()
    }

    /// Прокси демона либо nil, если демон не установлен или не отвечает.
    public func helper(
        errorHandler: @escaping @Sendable (Error) -> Void = { _ in }
    ) -> WetoHelperProtocol? {
        lock.lock()
        if connection == nil {
            let created = NSXPCConnection(
                machServiceName: WetoXPCConstants.machServiceName,
                options: .privileged
            )
            created.remoteObjectInterface = NSXPCInterface(with: WetoHelperProtocol.self)
            created.invalidationHandler = { [weak self] in self?.forgetConnection() }
            created.interruptionHandler = { [weak self] in self?.forgetConnection() }
            created.resume()
            connection = created
        }
        let current = connection
        lock.unlock()

        return current?.remoteObjectProxyWithErrorHandler { error in
            errorHandler(error)
        } as? WetoHelperProtocol
    }

    public func invalidate() {
        lock.lock()
        connection?.invalidate()
        connection = nil
        lock.unlock()
    }

    private func forgetConnection() {
        lock.lock()
        connection = nil
        lock.unlock()
    }
}
