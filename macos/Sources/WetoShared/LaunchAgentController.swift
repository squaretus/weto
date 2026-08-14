import Foundation
import Darwin
import AppKit

public enum LaunchAgentError: Error, Equatable, Sendable {
    case missingExecutable
    case write(String)
    case remove(String)
    case bootstrap(Int32)
    case bootout(Int32)

    public var displayText: String {
        switch self {
        case .missingExecutable:
            return "не удалось определить путь к исполняемому файлу приложения"
        case .write(let detail):
            return "не удалось записать файл автозапуска: \(detail)"
        case .remove(let detail):
            return "не удалось удалить файл автозапуска: \(detail)"
        case .bootstrap(let status):
            return "launchd отказался загружать агент (код \(status))"
        case .bootout(let status):
            return "launchd отказался выгружать агент (код \(status))"
        }
    }
}

/// Граница launchd и файла автозапуска. За протоколом — чтобы тумблер и удаление
/// проверялись без реальной регистрации агента в системе.
public protocol LaunchAgentManaging: Sendable {
    var plistPath: String { get }
    var isInstalled: Bool { get }
    var pointsAtCurrentBundle: Bool { get }

    func enable() -> Result<Void, LaunchAgentError>
    func disable() -> Result<Void, LaunchAgentError>
    func bootout() -> Result<Void, LaunchAgentError>
}

public struct LaunchAgentController: LaunchAgentManaging {

    public static let serviceName = "com.weto.app"

    /// Агент живёт только в домашнем каталоге пользователя. Установщик, приложение
    /// и удаление обязаны работать с этим же файлом: пока PKG клал агент
    /// в /Library/LaunchAgents, тумблер показывал неверное состояние,
    /// а удаление оставляло за собой запись, поднимавшую удалённый бинарник.
    public static var defaultPlistPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/LaunchAgents/\(serviceName).plist")
    }

    public let plistPath: String
    private let executablePathProvider: @Sendable () -> String?
    private let uid: uid_t
    private let launchdServiceName: @Sendable () -> String?
    private let launchctl: @Sendable ([String]) -> Int32

    public init(
        plistPath: String = LaunchAgentController.defaultPlistPath,
        executablePath: @escaping @Sendable () -> String? = { Bundle.main.executablePath },
        uid: uid_t = getuid(),
        launchdServiceName: @escaping @Sendable () -> String? = {
            ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"]
        },
        launchctl: (@Sendable ([String]) -> Int32)? = nil
    ) {
        self.plistPath = plistPath
        self.executablePathProvider = executablePath
        self.uid = uid
        self.launchdServiceName = launchdServiceName
        self.launchctl = launchctl ?? Self.runLaunchctl
    }

    /// Копию, поднятую launchd, launchd же и представляет заданием `com.weto.app`:
    /// имя сервиса он кладёт процессу в окружение. Такому процессу нельзя выгружать
    /// собственное задание — это SIGTERM самому себе.
    public var isRunningAsAgent: Bool {
        launchdServiceName() == Self.serviceName
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    public var pointsAtCurrentBundle: Bool {
        guard let executablePath = executablePathProvider(),
              let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any]
        else { return false }
        return plist["Program"] as? String == executablePath
    }

    public func enable() -> Result<Void, LaunchAgentError> {
        guard let executablePath = executablePathProvider() else {
            return .failure(.missingExecutable)
        }

        let plist: [String: Any] = [
            "Label": Self.serviceName,
            "Program": executablePath,
            "RunAtLoad": true,
            "KeepAlive": true,
        ]

        let directory = (plistPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            )
            try data.write(to: URL(fileURLWithPath: plistPath))
        } catch {
            return .failure(.write(error.localizedDescription))
        }

        // Мы и есть это задание: оно уже загружено и работает, а перерегистрация
        // означала бы выгрузку самого себя. Достаточно верного файла на диске.
        if isRunningAsAgent { return .success(()) }

        // Перед загрузкой снимаем прежнюю регистрацию: launchd иначе откажет,
        // если агент уже загружен с другим путём.
        _ = launchctl(["bootout", "gui/\(uid)/\(Self.serviceName)"])

        let status = launchctl(["bootstrap", "gui/\(uid)", plistPath])
        return status == 0 ? .success(()) : .failure(.bootstrap(status))
    }

    public func disable() -> Result<Void, LaunchAgentError> {
        let hadAgent = FileManager.default.fileExists(atPath: plistPath)

        // Отключение автозапуска не должно завершать работающее приложение:
        // когда задание — это мы сами, снимаем только файл. Загруженное задание
        // launchd отпустит при выходе из системы, и обратно приложение не вернётся.
        if isRunningAsAgent {
            if hadAgent {
                do {
                    try FileManager.default.removeItem(atPath: plistPath)
                } catch {
                    return .failure(.remove(error.localizedDescription))
                }
            }
            return .success(())
        }

        // Порядок важен: сначала выгрузка, потом удаление файла. Иначе launchd
        // держит задание, ссылающееся на исчезнувший plist.
        let status = launchctl(["bootout", "gui/\(uid)/\(Self.serviceName)"])

        if hadAgent {
            do {
                try FileManager.default.removeItem(atPath: plistPath)
            } catch {
                return .failure(.remove(error.localizedDescription))
            }
        }

        // Отказ launchd — ошибка только тогда, когда агент был установлен:
        // «выгружать нечего» не должно выглядеть сбоем.
        guard !hadAgent || status == 0 || status == launchdNotLoaded else {
            return .failure(.bootout(status))
        }
        return .success(())
    }

    /// Выгрузка задания как таковая. Вызывается только тем, кто и намерен завершить
    /// приложение (`Maintenance.closeApp`), — здесь SIGTERM самому себе уместен.
    public func bootout() -> Result<Void, LaunchAgentError> {
        let status = launchctl(["bootout", "gui/\(uid)/\(Self.serviceName)"])
        return status == 0 || status == launchdNotLoaded ? .success(()) : .failure(.bootout(status))
    }

    /// launchctl возвращает 3, когда выгружать было нечего, — это не ошибка.
    private let launchdNotLoaded: Int32 = 3

    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
