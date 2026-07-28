import Foundation

public enum WetoXPCConstants {
    public static let machServiceName = "com.weto.helper"

    /// Версия XPC-поверхности, развязанная с версией приложения: релизный скрипт
    /// её не подставляет. Бампается вручную при изменении протокола, чтобы клиент
    /// мог отказаться работать со старым демоном.
    public static let protocolVersion = "1.0.0"
}
