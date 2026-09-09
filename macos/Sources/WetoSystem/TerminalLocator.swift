import Foundation
import AppKit
import WetoCore

/// Показать терминал, в котором живёт цель, ушедшая в фон по запасному пути паузы.
/// Ввод `fg` за пользователя не делаем: это возможно только для Terminal.app и iTerm2
/// через AppleScript с разрешением Automation, остальные эмуляторы этого не умеют.
public protocol TerminalLocating: Sendable {
    func activateTerminal(owning pid: Int32, in processes: [ProcessSnapshot]) -> Bool
}

public struct TerminalLocator: TerminalLocating {

    public init() {}

    public func activateTerminal(owning pid: Int32, in processes: [ProcessSnapshot]) -> Bool {
        guard let host = Self.hostApplicationPID(of: pid, in: processes),
              let application = NSRunningApplication(processIdentifier: host)
        else { return false }
        return application.activate()
    }

    /// Самый верхний предок, чей путь лежит внутри `.app`-бандла. Верхний, а не первый:
    /// у VS Code шелл живёт под хелпером, который сам в бандле, а активировать надо окно.
    public static func hostApplicationPID(of pid: Int32, in processes: [ProcessSnapshot]) -> Int32? {
        var byPID: [Int32: ProcessSnapshot] = [:]
        for process in processes { byPID[process.pid] = process }
        let tree = ProcessTree(processes: processes)
        return tree.ancestors(of: pid)
            .filter { byPID[$0]?.executablePath.contains(".app/Contents/") == true }
            .last
    }
}
