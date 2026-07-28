import Foundation

/// Отображение ответов демона в результаты, пригодные для UI.
/// Вынесено из VM, чтобы разбор XPC-ответа проверялся без живого демона.
public enum UpdateService {

    public enum InstallResult: Equatable, Sendable {
        case started
        case failed(String)
    }

    public static func install(
        helper: WetoHelperProtocol,
        completion: @escaping @Sendable (InstallResult) -> Void
    ) {
        helper.performUpdate { error in
            completion(error.map(InstallResult.failed) ?? .started)
        }
    }

    /// Провал установки, случившийся уже после ответа «начата».
    public static func lastFailure(
        helper: WetoHelperProtocol,
        completion: @escaping @Sendable (String?) -> Void
    ) {
        helper.lastInstallFailure { failure in
            completion(failure)
        }
    }
}
