import Foundation

public struct ProcessSnapshot: Equatable, Sendable {
    public let pid: Int32

    public let parentPID: Int32
    public let executablePath: String

    /// argv процесса как есть, без склейки в строку: склеенную командную строку
    /// нельзя сопоставлять с путём цели — подстрока совпадает с чужой обёрткой
    /// и с пользовательскими данными команды.
    public let arguments: [String]?

    /// Группа процессов (`pbi_pgid`). 0 — неизвестно.
    public let processGroup: Int32

    /// Передняя группа управляющего терминала (`e_tpgid`). 0 — терминала нет.
    /// Совпадает с `processGroup` у переднего задания интерактивного шелла.
    public let terminalForegroundGroup: Int32

    /// Уже остановлен (`SSTOP`) — пользовательский Ctrl-Z, не наша пауза.
    public let isStopped: Bool

    public init(
        pid: Int32,
        parentPID: Int32 = 0,
        executablePath: String,
        arguments: [String]? = nil,
        processGroup: Int32 = 0,
        terminalForegroundGroup: Int32 = 0,
        isStopped: Bool = false
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.executablePath = executablePath
        self.arguments = arguments
        self.processGroup = processGroup
        self.terminalForegroundGroup = terminalForegroundGroup
        self.isStopped = isStopped
    }
}
