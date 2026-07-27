import Foundation
import AppKit
import WetoCore
import WetoSystem

/// Выгрузка и полное удаление приложения.
///
/// Обе операции завершают процесс, поэтому убирать за собой надо до выхода.
/// Порядок важен: сначала снимается LaunchAgent, иначе launchd поднимет
/// приложение обратно раньше, чем закончится удаление файлов.
public enum Maintenance {

    /// Что удалять при полном сносе. Порядок отражает порядок выполнения.
    public struct Report: Equatable, Sendable {
        public var removed: [String] = []
        public var failed: [String] = []
    }

    /// Снимает автозапуск, оставляя файлы и настройки нетронутыми.
    public static func unload() {
        LaunchAgentController.disable()
    }

    /// Полное удаление: автозапуск, бандл, настройки, токен, кэши, журнал.
    ///
    /// Бандл сносится последним и через отложенный шелл: процесс не может
    /// удалить собственный исполняемый файл и остаться работоспособным,
    /// поэтому удаление происходит уже после выхода.
    @discardableResult
    public static func uninstall() -> Report {
        var report = Report()

        LaunchAgentController.disable()
        report.removed.append("автозапуск")

        let defaults = UserDefaults(suiteName: Constants.userDefaultsSuite)
        defaults?.removePersistentDomain(forName: Constants.userDefaultsSuite)
        UserDefaults.standard.removePersistentDomain(forName: Constants.userDefaultsSuite)
        report.removed.append("настройки и журнал")

        if KeychainStore(service: Constants.keychainService).write(nil, account: "token") {
            report.removed.append("токен ipinfo")
        } else {
            report.failed.append("токен ipinfo")
        }

        let caches = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.weto.app", isDirectory: true)
        if let caches, FileManager.default.fileExists(atPath: caches.path) {
            if (try? FileManager.default.removeItem(at: caches)) != nil {
                report.removed.append("кэш флагов")
            } else {
                report.failed.append("кэш флагов")
            }
        }

        if let bundlePath = bundlePathToRemove() {
            scheduleBundleRemoval(at: bundlePath)
            report.removed.append("приложение (\(bundlePath))")
        }

        return report
    }

    // MARK: - Private

    /// Путь к `.app`, если приложение действительно запущено из бандла.
    /// При запуске голого бинарника (`swift run`) удалять нечего.
    private static func bundlePathToRemove() -> String? {
        let path = Bundle.main.bundlePath
        return path.hasSuffix(".app") ? path : nil
    }

    /// Удаление бандла после выхода: отсоединённый процесс ждёт исчезновения
    /// родителя и только затем сносит каталог.
    private static func scheduleBundleRemoval(at path: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
            while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
            rm -rf '\(path.replacingOccurrences(of: "'", with: "'\\''"))'
            """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        try? process.run()
    }
}
