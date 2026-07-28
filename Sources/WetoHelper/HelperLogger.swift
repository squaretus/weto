import Foundation
import os

/// Журнал демона. У root-процесса нет пользовательского интерфейса, поэтому
/// единственный способ понять, что произошло при установке, — системный лог.
enum HelperLogger {

    private static let logger = Logger(subsystem: "com.weto.helper", category: "Helper")

    static func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
