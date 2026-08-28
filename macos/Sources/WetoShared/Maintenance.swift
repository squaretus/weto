import Foundation
import AppKit
import WetoCore
import WetoSystem
import UpdateKit

/// Что именно делает удаление. План отделён от исполнения, чтобы порядок шагов
/// и их состав проверялись без реального сноса приложения.
public enum MaintenanceStep: Equatable, Sendable {
    case unloadAgent
    case removeAgentFile
    case clearSettings
    case removeToken
    case removeCaches
    case removeJournals
    case removeHelper
    case removeBundle

    public var displayText: String {
        switch self {
        case .unloadAgent: return "выгрузка автозапуска"
        case .removeAgentFile: return "удаление файла автозапуска"
        case .clearSettings: return "очистка настроек и журнала"
        case .removeToken: return "удаление токена ipinfo"
        case .removeCaches: return "удаление кэша флагов"
        case .removeJournals: return "удаление журналов"
        case .removeHelper: return "снятие демона обновления"
        case .removeBundle: return "удаление самого приложения"
        }
    }
}

public struct MaintenanceResult: Equatable, Sendable {
    public var completed: [MaintenanceStep] = []
    public var failures: [(step: MaintenanceStep, detail: String)] = []

    public var isSuccess: Bool { failures.isEmpty }

    public var failureText: String? {
        guard !isSuccess else { return nil }
        return failures
            .map { "\($0.step.displayText): \($0.detail)" }
            .joined(separator: "\n")
    }

    public static func == (lhs: MaintenanceResult, rhs: MaintenanceResult) -> Bool {
        lhs.completed == rhs.completed
            && lhs.failures.map(\.step) == rhs.failures.map(\.step)
            && lhs.failures.map(\.detail) == rhs.failures.map(\.detail)
    }
}

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

public struct Maintenance {

    private let agent: LaunchAgentManaging
    private let secrets: SecretStoring
    private let defaultsSuite: String
    private let cachesDirectory: URL?

    /// Журналы завершений и проверок: отдельный каталог, и удаление про него
    /// не знало вовсе — после «удалить приложение» на диске оставалась история.
    private let journalsDirectory: URL?

    private let bundlePath: String?
    private let fileManager: FileManager
    private let helper: HelperUninstalling?

    public init(
        agent: LaunchAgentManaging = LaunchAgentController(),
        helper: HelperUninstalling? = HelperUpdateInstaller(configuration: WetoUpdate.configuration),
        secrets: SecretStoring = KeychainStore(service: Constants.keychainService),
        defaultsSuite: String = Constants.userDefaultsSuite,
        cachesDirectory: URL? = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.weto.app", isDirectory: true),
        journalsDirectory: URL? = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(JournalFile.directoryName, isDirectory: true),
        bundlePath: String? = Bundle.main.bundlePath.hasSuffix(".app")
            ? Bundle.main.bundlePath
            : nil,
        fileManager: FileManager = .default
    ) {
        self.agent = agent
        self.helper = helper
        self.secrets = secrets
        self.defaultsSuite = defaultsSuite
        self.cachesDirectory = cachesDirectory
        self.journalsDirectory = journalsDirectory
        self.bundlePath = bundlePath
        self.fileManager = fileManager
    }

    /// Приложение уходит до следующего входа в систему: агент выгружается,
    /// но его файл остаётся — иначе автозапуск пришлось бы включать заново.
    public func closeApp() -> Result<Void, LaunchAgentError> {
        agent.bootout()
    }

    public func uninstall() -> MaintenanceResult {
        var result = MaintenanceResult()

        // Первым шагом — выгрузка: удалять файл автозапуска у загруженного
        // задания значит оставить launchd со ссылкой в пустоту.
        switch agent.disable() {
        case .success:
            result.completed.append(.unloadAgent)
            result.completed.append(.removeAgentFile)
        case .failure(let error):
            result.failures.append((.unloadAgent, error.displayText))
        }

        UserDefaults(suiteName: defaultsSuite)?.removePersistentDomain(forName: defaultsSuite)
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
        result.completed.append(.clearSettings)

        remove(journalsDirectory, as: .removeJournals, into: &result)

        switch secrets.write(nil, account: "token") {
        case .success:
            result.completed.append(.removeToken)
        case .failure(let error):
            result.failures.append((.removeToken, error.displayText))
        }

        remove(cachesDirectory, as: .removeCaches, into: &result)

        // Демон снимает сам себя: у приложения нет прав на /Library.
        if let helper {
            let failure = Self.awaitHelperUninstall(helper)
            if let failure {
                result.failures.append((.removeHelper, failure))
            } else {
                result.completed.append(.removeHelper)
            }
        }

        // Бандл сносит демон: он принадлежит root, потому что его ставит PKG,
        // и у приложения нет прав ни на запись в него, ни на его удаление.
        // Результат проверяется, а не предполагается: раньше удаление запускало
        // скрипт от пользователя, рапортовало об успехе по факту запуска —
        // и приложение оставалось на диске без единого слова об этом.
        if let bundlePath {
            if fileManager.fileExists(atPath: bundlePath) {
                result.failures.append((
                    .removeBundle,
                    "приложение осталось в \(bundlePath) — удалите его вручную"
                ))
            } else {
                result.completed.append(.removeBundle)
            }
        }

        return result
    }

    private func remove(
        _ directory: URL?,
        as step: MaintenanceStep,
        into result: inout MaintenanceResult
    ) {
        guard let directory, fileManager.fileExists(atPath: directory.path) else { return }
        do {
            try fileManager.removeItem(at: directory)
            result.completed.append(step)
        } catch {
            result.failures.append((step, error.localizedDescription))
        }
    }

    /// Ответ демона ждём ограниченное время: удаление не должно зависнуть,
    /// если демона нет или он не отвечает.
    private static func awaitHelperUninstall(_ helper: HelperUninstalling) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = FailureBox()

        helper.uninstallHelper { failure in
            box.value = failure
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 5) == .timedOut {
            return "демон не ответил за 5 секунд"
        }
        return box.value
    }

}
