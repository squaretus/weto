import Foundation

public struct ProcessSnapshot: Equatable, Sendable {
    public let pid: Int32

    public let parentPID: Int32
    public let executablePath: String

    /// argv процесса как есть, без склейки в строку: склеенную командную строку
    /// нельзя сопоставлять с путём цели — подстрока совпадает с чужой обёрткой
    /// и с пользовательскими данными команды.
    public let arguments: [String]?

    public init(
        pid: Int32,
        parentPID: Int32 = 0,
        executablePath: String,
        arguments: [String]? = nil
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.executablePath = executablePath
        self.arguments = arguments
    }
}
