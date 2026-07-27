import Foundation
import Darwin

/// Результат попытки завершить один процесс.
///
/// `errorCode == nil` — успех. `EPERM` — процесс принадлежит другому
/// пользователю или root: это не проглатывается, а показывается в UI как
/// отказ охраны. `ESRCH` — процесс уже умер сам, это не ошибка по существу.
public struct KillResult: Equatable, Sendable {
    public let pid: Int32
    public let errorCode: Int32?

    public init(pid: Int32, errorCode: Int32?) {
        self.pid = pid
        self.errorCode = errorCode
    }

    /// Процесс гарантированно не работает: либо убит нами, либо умер раньше.
    public var isTerminated: Bool { errorCode == nil || errorCode == ESRCH }
}

/// Граница системы: завершение процессов.
public protocol ProcessKilling: Sendable {
    func kill(pids: [Int32]) -> [KillResult]
}

/// Безусловный SIGKILL.
///
/// Мягкое завершение через `NSRunningApplication.terminate()` отклонено
/// осознанно: приложение может показать диалог сохранения и продолжить работать.
public struct ProcessKiller: ProcessKilling {

    public init() {}

    public func kill(pids: [Int32]) -> [KillResult] {
        pids.map { pid in
            let status = Darwin.kill(pid, SIGKILL)
            return KillResult(pid: pid, errorCode: status == 0 ? nil : errno)
        }
    }
}
