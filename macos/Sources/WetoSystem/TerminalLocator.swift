import Foundation
import AppKit
import WetoCore

/// Показать терминал, в котором живёт цель, ушедшая в фон по запасному пути паузы.
/// Запасной путь и есть: `fg` за пользователя вводит `TerminalForegroundReturner`, а сюда
/// приходят, когда ввести нечем и остаётся подсказка.
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
    ///
    /// Под Terminal.app цепочку рвёт `login`: он принадлежит root, и `proc_pidinfo` родителя
    /// не отдаёт. Его спрашиваем у ядра через `sysctl`, только здесь: общий обход процессов это
    /// менять не должно, иначе у цели Terminal.app потомками стали бы все шеллы её окон.
    public static func hostApplicationPID(
        of pid: Int32,
        in processes: [ProcessSnapshot],
        parentOf: (Int32) -> Int32? = kernelParent(of:)
    ) -> Int32? {
        var byPID: [Int32: ProcessSnapshot] = [:]
        for process in processes { byPID[process.pid] = process }

        var host: Int32?
        var current = pid
        for _ in 0...processes.count {
            let known = byPID[current]?.parentPID ?? 0
            let parent = known > 0 ? known : parentOf(current) ?? 0
            guard parent > 0, parent != current else { break }
            if byPID[parent]?.executablePath.contains(".app/Contents/") == true { host = parent }
            current = parent
        }
        return host
    }

    public static func kernelParent(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&query, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
