import Foundation
import Darwin
import UpdateKitCore

/// Кто имеет право говорить с демоном.
///
/// **Контекст:** у проекта может не быть Apple Developer ID, и тогда проверка
/// через `SecCodeCheckValidity` с requirement по team-id неприменима — сверять
/// нечего. До появления подписи используется путь исполняемого файла клиента:
/// pid → `proc_pidpath` → сравнение со списком из конфигурации.
///
/// **Модель угроз:** отсекает посторонние пользовательские процессы, которые могли бы
/// вызвать `performUpdate`. НЕ защищает от root: root может подменить сам бинарник
/// по разрешённому пути. Это осознанно принятый предел — без root противник не получает
/// через XPC ничего, чего не мог бы сделать напрямую.
///
/// Появится Developer ID — заменить на `SecCodeCheckValidity` с requirement по team-id.
public struct ClientAuthorization: Sendable {

    private let configuration: UpdateFeedConfiguration

    public init(configuration: UpdateFeedConfiguration) {
        self.configuration = configuration
    }

    /// `PROC_PIDPATHINFO_MAXSIZE` не экспортируется в Swift, поэтому размер буфера
    /// задан литералом — это то же зафиксированное значение 4 * MAXPATHLEN.
    public static func executablePath(forPID pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    public func isAuthorized(pid: pid_t) -> Bool {
        guard let path = Self.executablePath(forPID: pid) else { return false }
        if configuration.clientExecutablePaths.contains(path) { return true }
        #if DEBUG
        // Пути dev-сборок проверяются только в отладочной сборке демона:
        // в релизном пакете этого кода нет.
        if configuration.debugClientExecutableSuffixes.contains(where: { path.hasSuffix($0) }) {
            return true
        }
        #endif
        return false
    }
}
