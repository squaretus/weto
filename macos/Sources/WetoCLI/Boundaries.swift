import Darwin
import Foundation
import WetoCore
import WetoSystem

/// Куда печатает команда. Граница — чтобы вывод проверялся тестом дословно.
protocol CLIOutput: AnyObject {
    func out(_ line: String)
    func err(_ line: String)
}

final class StandardOutput: CLIOutput {
    func out(_ line: String) { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }
    func err(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }
}

/// Запуск `launchctl`. Граница системы: в тестах сервис не регистрируется
/// в настоящем launchd пользователя.
protocol ServiceControlling: Sendable {
    func launchctl(_ arguments: [String]) -> (status: Int32, output: String)
}

struct Launchctl: ServiceControlling {
    func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// Запущено ли приложение Weto. Две охраны над одними целями дерутся
/// SIGSTOP/SIGCONT, поэтому `run` при живом приложении не стартует.
protocol WetoAppDetecting: Sendable {
    var isWetoAppRunning: Bool { get }
}

/// Приложение ищется обходом процессов, а не `NSRunningApplication`: у LaunchDaemon
/// от root нет сессии окна, и спросить её о приложениях пользователей он не может.
/// Обход видит процессы всех пользователей разом.
struct WetoAppProcessDetector: WetoAppDetecting {
    let locator: ProcessLocating

    var isWetoAppRunning: Bool {
        locator.allProcesses(includeArguments: false).contains { Self.isWetoApp($0.executablePath) }
    }

    /// Главный процесс приложения — исполняемый файл внутри `Weto.app/Contents/MacOS/`,
    /// где бы бандл ни лежал: в `/Applications`, в `~/Applications` или в каталоге сборки.
    static func isWetoApp(_ path: String) -> Bool {
        path.contains("/Weto.app/Contents/MacOS/")
    }
}

/// Живость и сигнал процессу охраны: `status` проверяет pid из файла статуса,
/// `check` будит охрану `SIGUSR1`.
protocol GuardProcessSignaling: Sendable {
    func isAlive(_ pid: Int32) -> Bool
    func requestCheck(_ pid: Int32) -> Bool
}

struct KernelGuardProcess: GuardProcessSignaling {
    func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        // EPERM — процесс есть, но чужой: живой.
        return kill(pid, 0) == 0 || errno == EPERM
    }

    func requestCheck(_ pid: Int32) -> Bool {
        pid > 0 && kill(pid, SIGUSR1) == 0
    }
}
