import Foundation
import WetoCore

/// Отображение ответов демона в результаты, пригодные для UI.
/// Вынесено из VM, чтобы разбор XPC-ответа проверялся без живого демона.
public enum UpdateService {

    public enum CheckResult: Equatable, Sendable {
        case available(UpdateInfo)
        case upToDate(currentVersion: String)
        case failed(String)
    }

    public enum InstallResult: Equatable, Sendable {
        case started
        case failed(String)
    }

    public static func result(data: Data?, error: String?) -> CheckResult {
        if let error { return .failed(error) }
        guard let data, let info = try? JSONDecoder().decode(UpdateInfo.self, from: data) else {
            return .failed("Не удалось разобрать ответ демона")
        }
        return info.isNewer ? .available(info) : .upToDate(currentVersion: info.currentVersion)
    }

    public static func checkForced(
        helper: WetoHelperProtocol,
        completion: @escaping @Sendable (CheckResult) -> Void
    ) {
        helper.checkForUpdateForced { data, error in
            completion(result(data: data, error: error))
        }
    }

    public static func install(
        helper: WetoHelperProtocol,
        completion: @escaping @Sendable (InstallResult) -> Void
    ) {
        helper.performUpdate { error in
            completion(error.map(InstallResult.failed) ?? .started)
        }
    }
}
