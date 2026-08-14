import Foundation

/// Отображение ответов демона в результаты, пригодные для UI.
/// Вынесено из контроллера, чтобы разбор ответа проверялся без живого демона.
public enum UpdaterService {

    public enum InstallResult: Equatable, Sendable {
        case started
        case failed(String)
    }

    public static func install(
        helper: UpdaterHelperProtocol,
        completion: @escaping @Sendable (InstallResult) -> Void
    ) {
        helper.performUpdate { error in
            completion(error.map(InstallResult.failed) ?? .started)
        }
    }

    /// Тройка отдаётся как есть: превращать её в доменный тип — дело `UpdateKitCore`,
    /// а этот таргет намеренно не имеет зависимостей.
    public static func state(
        helper: UpdaterHelperProtocol,
        completion: @escaping @Sendable (Int, Double, String?) -> Void
    ) {
        helper.installState { phase, fraction, failure in
            completion(phase, fraction, failure)
        }
    }
}
