import Foundation
import AppKit
import WetoCore
import WetoSystem

/// Что именно делает удаление. План отделён от исполнения, чтобы порядок шагов
/// и их состав проверялись без реального сноса приложения.
public enum MaintenanceStep: Equatable, Sendable {
    case unloadAgent
    case removeAgentFile
    case clearSettings
    case removeToken
    case removeCaches
    case removeHelper
    case scheduleBundleRemoval

    public var displayText: String {
        switch self {
        case .unloadAgent: return "выгрузка автозапуска"
        case .removeAgentFile: return "удаление файла автозапуска"
        case .clearSettings: return "очистка настроек и журнала"
        case .removeToken: return "удаление токена ipinfo"
        case .removeCaches: return "удаление кэша флагов"
        case .removeHelper: return "снятие демона обновления"
        case .scheduleBundleRemoval: return "удаление самого приложения"
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
    private let bundlePath: String?
    private let fileManager: FileManager
    private let removeBundle: @Sendable (String) -> Result<Void, Error>
    private let helper: HelperUninstalling?

    public init(
        agent: LaunchAgentManaging = LaunchAgentController(),
        helper: HelperUninstalling? = HelperUpdateInstaller(),
        secrets: SecretStoring = KeychainStore(service: Constants.keychainService),
        defaultsSuite: String = Constants.userDefaultsSuite,
        cachesDirectory: URL? = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.weto.app", isDirectory: true),
        bundlePath: String? = Bundle.main.bundlePath.hasSuffix(".app")
            ? Bundle.main.bundlePath
            : nil,
        fileManager: FileManager = .default,
        removeBundle: @escaping @Sendable (String) -> Result<Void, Error> = Maintenance.scheduleBundleRemoval
    ) {
        self.agent = agent
        self.helper = helper
        self.secrets = secrets
        self.defaultsSuite = defaultsSuite
        self.cachesDirectory = cachesDirectory
        self.bundlePath = bundlePath
        self.fileManager = fileManager
        self.removeBundle = removeBundle
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

        switch secrets.write(nil, account: "token") {
        case .success:
            result.completed.append(.removeToken)
        case .failure(let error):
            result.failures.append((.removeToken, error.displayText))
        }

        if let cachesDirectory, fileManager.fileExists(atPath: cachesDirectory.path) {
            do {
                try fileManager.removeItem(at: cachesDirectory)
                result.completed.append(.removeCaches)
            } catch {
                result.failures.append((.removeCaches, error.localizedDescription))
            }
        }

        // Демон снимает сам себя: у приложения нет прав на /Library.
        if let helper {
            let failure = Self.awaitHelperUninstall(helper)
            if let failure {
                result.failures.append((.removeHelper, failure))
            } else {
                result.completed.append(.removeHelper)
            }
        }

        if let bundlePath {
            switch removeBundle(bundlePath) {
            case .success:
                result.completed.append(.scheduleBundleRemoval)
            case .failure(let error):
                result.failures.append((.scheduleBundleRemoval, error.localizedDescription))
            }
        }

        return result
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

    /// Бандл нельзя удалить из самого работающего приложения, поэтому удаление
    /// делает отдельный процесс, дождавшись выхода нашего.
    public static let scheduleBundleRemoval: @Sendable (String) -> Result<Void, Error> = { path in
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
            while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
            rm -rf '\(path.replacingOccurrences(of: "'", with: "'\\''"))'
            """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        do {
            try process.run()
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
