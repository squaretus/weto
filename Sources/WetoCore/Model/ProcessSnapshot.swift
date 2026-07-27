import Foundation

public struct ProcessSnapshot: Equatable, Sendable {
    public let pid: Int32

    public let parentPID: Int32
    public let executablePath: String
    public let arguments: String?

    public init(
        pid: Int32,
        parentPID: Int32 = 0,
        executablePath: String,
        arguments: String? = nil
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.executablePath = executablePath
        self.arguments = arguments
    }
}
