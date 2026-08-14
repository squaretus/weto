import Foundation
import Darwin

public struct KillResult: Equatable, Sendable {
    public let pid: Int32
    public let errorCode: Int32?

    public init(pid: Int32, errorCode: Int32?) {
        self.pid = pid
        self.errorCode = errorCode
    }

    public var isTerminated: Bool { errorCode == nil || errorCode == ESRCH }
}

public protocol ProcessKilling: Sendable {
    func kill(pids: [Int32]) -> [KillResult]
}

public struct ProcessKiller: ProcessKilling {

    public init() {}

    public func kill(pids: [Int32]) -> [KillResult] {
        pids.map { pid in
            let status = Darwin.kill(pid, SIGKILL)
            return KillResult(pid: pid, errorCode: status == 0 ? nil : errno)
        }
    }
}
