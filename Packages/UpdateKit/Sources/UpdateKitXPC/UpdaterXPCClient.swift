import Foundation

/// Клиент привилегированного демона. Соединение поднимается лениво и
/// переустанавливается после разрыва: демон умирает при установке обновления,
/// потому что установщик его выгружает.
public final class UpdaterXPCClient: @unchecked Sendable {

    private let machServiceName: String
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    public init(machServiceName: String) {
        self.machServiceName = machServiceName
    }

    deinit {
        connection?.invalidate()
    }

    /// Прокси демона либо nil, если демон не установлен или не отвечает.
    public func helper(
        errorHandler: @escaping @Sendable (Error) -> Void = { _ in }
    ) -> UpdaterHelperProtocol? {
        lock.lock()
        if connection == nil {
            let created = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
            created.remoteObjectInterface = NSXPCInterface(with: UpdaterHelperProtocol.self)
            created.invalidationHandler = { [weak self] in self?.forgetConnection() }
            created.interruptionHandler = { [weak self] in self?.forgetConnection() }
            created.resume()
            connection = created
        }
        let current = connection
        lock.unlock()

        return current?.remoteObjectProxyWithErrorHandler { error in
            errorHandler(error)
        } as? UpdaterHelperProtocol
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
