import Foundation
import Darwin

/// Кто имеет право говорить с демоном.
///
/// **Контекст:** у проекта нет Apple Developer ID, поэтому проверка через
/// `SecCodeCheckValidity` с requirement по team-id неприменима — сверять нечего.
/// До появления подписи используем путь исполняемого файла клиента:
/// pid → `proc_pidpath` → сравнение с белым списком.
///
/// **Модель угроз:** отсекает посторонние пользовательские процессы, которые могли бы
/// вызвать `performUpdate`. НЕ защищает от root: root может подменить сам бинарник
/// по разрешённому пути. Это осознанно принятый предел — без root противник не получает
/// через XPC ничего, чего не мог бы сделать напрямую.
///
/// Появится Developer ID — заменить на `SecCodeCheckValidity` с requirement по team-id.
enum ClientAuthorization {

    static let installedPaths: [String] = [
        "/Applications/Weto.app/Contents/MacOS/WetoMenuBar",
    ]

    /// Пути dev-сборок. Компилируются только в отладочной сборке демона:
    /// в релизном PKG этого кода нет.
    static let debugPathSuffixes: [String] = [
        "/.build/debug/WetoMenuBar",
        "/.build/release/WetoMenuBar",
        "/.build/app/Weto.app/Contents/MacOS/WetoMenuBar",
    ]

    /// `PROC_PIDPATHINFO_MAXSIZE` не экспортируется в Swift, поэтому размер буфера
    /// задан литералом — это то же зафиксированное значение 4 * MAXPATHLEN.
    static func executablePath(forPID pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static func isAuthorized(pid: pid_t) -> Bool {
        guard let path = executablePath(forPID: pid) else { return false }
        if installedPaths.contains(path) { return true }
        #if DEBUG
        if debugPathSuffixes.contains(where: { path.hasSuffix($0) }) { return true }
        #endif
        return false
    }
}
