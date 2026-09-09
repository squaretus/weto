import Foundation
import Darwin

public enum ProcessSignal: Equatable, Sendable {
    case kill
    case stop
    case resume

    var number: Int32 {
        switch self {
        case .kill: return SIGKILL
        case .stop: return SIGSTOP
        case .resume: return SIGCONT
        }
    }
}

public struct SignalResult: Equatable, Sendable {
    public let pid: Int32
    public let errorCode: Int32?

    public init(pid: Int32, errorCode: Int32?) {
        self.pid = pid
        self.errorCode = errorCode
    }

    /// Процесс, исчезнувший до сигнала, — не отказ: цель достигнута.
    public var isDelivered: Bool { errorCode == nil || errorCode == ESRCH }
}

/// Единственное место, где приложение вмешивается в чужую жизнь.
///
/// Сигналы уходят строго в порядке списка: для паузы переднего задания порядок
/// «шелл, затем цель» и обратный при продолжении — часть контракта, а не деталь.
public protocol ProcessSignaling: Sendable {
    func send(_ signal: ProcessSignal, to pids: [Int32]) -> [SignalResult]
}

public struct ProcessSignaler: ProcessSignaling {

    public init() {}

    public func send(_ signal: ProcessSignal, to pids: [Int32]) -> [SignalResult] {
        pids.map { pid in
            let status = Darwin.kill(pid, signal.number)
            return SignalResult(pid: pid, errorCode: status == 0 ? nil : errno)
        }
    }
}
