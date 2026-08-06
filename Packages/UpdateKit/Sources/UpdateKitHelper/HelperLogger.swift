import Foundation
import os

/// Журнал демона. У root-процесса нет пользовательского интерфейса, поэтому
/// единственный способ понять, что произошло при установке, — системный лог.
public struct HelperLogger: Sendable {

    private let logger: Logger

    public init(subsystem: String) {
        self.logger = Logger(subsystem: subsystem, category: "Helper")
    }

    public func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
