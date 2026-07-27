import Foundation
import Darwin
import AppKit

/// Автозапуск через пользовательский LaunchAgent.
///
/// Агент ставится в `~/Library/LaunchAgents` и потому не требует root —
/// в отличие от системного `/Library/LaunchAgents`, который появится
/// вместе с PKG-установщиком.
///
/// `KeepAlive = true` осознанно: падение сторожевого приложения означает
/// потерю защиты, поэтому launchd обязан поднимать его обратно.
public enum LaunchAgentController {

    public static let serviceName = "com.weto.app"

    public static var plistPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/LaunchAgents/\(serviceName).plist")
    }

    /// Путь к исполняемому файлу внутри текущего бандла.
    private static var executablePath: String? {
        Bundle.main.executablePath
    }

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    /// Установлен ли агент и указывает ли он на *этот* бандл.
    /// Расхождение возможно после переноса приложения в другую папку.
    public static var pointsAtCurrentBundle: Bool {
        guard let executablePath,
              let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any]
        else { return false }
        return plist["Program"] as? String == executablePath
    }

    @discardableResult
    public static func enable() -> Bool {
        guard let executablePath else { return false }

        let plist: [String: Any] = [
            "Label": serviceName,
            "Program": executablePath,
            "RunAtLoad": true,
            "KeepAlive": true,
        ]

        let directory = (plistPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )

        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        ), (try? data.write(to: URL(fileURLWithPath: plistPath))) != nil
        else { return false }

        // bootout перед bootstrap: launchd отказывается перезагружать
        // уже зарегистрированную службу и возвращает ошибку 5.
        runLaunchctl(["bootout", "gui/\(getuid())/\(serviceName)"])
        return runLaunchctl(["bootstrap", "gui/\(getuid())", plistPath])
    }

    @discardableResult
    public static func disable() -> Bool {
        runLaunchctl(["bootout", "gui/\(getuid())/\(serviceName)"])
        try? FileManager.default.removeItem(atPath: plistPath)
        return true
    }

    // MARK: - Private

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
