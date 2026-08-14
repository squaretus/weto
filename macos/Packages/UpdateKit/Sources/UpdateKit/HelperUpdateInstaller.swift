import Foundation
import UpdateKitCore
import UpdateKitXPC

/// Установка через привилегированный демон: единственная реализация
/// `UpdateInstalling`, которая действительно ходит за root.
public struct HelperUpdateInstaller: UpdateInstalling, HelperUninstalling {

    private let client: UpdaterXPCClient

    public init(configuration: UpdateFeedConfiguration) {
        self.client = UpdaterXPCClient(machServiceName: configuration.machServiceName)
    }

    public func requestInstall(
        completion: @escaping @Sendable (UpdaterService.InstallResult?) -> Void
    ) {
        // Одно и то же завершение может прийти и из errorHandler соединения,
        // и из ответа демона — пропускаем только первое.
        let answered = AnsweredOnce<UpdaterService.InstallResult?>(completion)

        guard let helper = client.helper(errorHandler: { _ in answered.finish(nil) }) else {
            answered.finish(nil)
            return
        }

        UpdaterService.install(helper: helper) { result in answered.finish(result) }
    }

    public func requestProgress(completion: @escaping @Sendable (UpdateProgress?) -> Void) {
        let answered = AnsweredOnce<UpdateProgress?>(completion)

        // Демон умирает вместе с установкой — молчание здесь нормально
        // и означает «сказать нечего», а не «сбой».
        guard let helper = client.helper(errorHandler: { _ in answered.finish(nil) }) else {
            answered.finish(nil)
            return
        }

        UpdaterService.state(helper: helper) { phase, fraction, failure in
            answered.finish(UpdateProgress.fromXPC(phase: phase, fraction: fraction, failure: failure))
        }
    }

    public func uninstallHelper(completion: @escaping @Sendable (String?) -> Void) {
        let answered = AnsweredOnce<String?>(completion)

        // Демона может не быть вовсе — это не ошибка удаления.
        guard let helper = client.helper(errorHandler: { _ in answered.finish(nil) }) else {
            answered.finish(nil)
            return
        }
        helper.uninstallHelper { failure in answered.finish(failure) }
    }
}

/// Завершение, которое срабатывает ровно один раз: ответ может прийти
/// и от демона, и от обработчика ошибки соединения.
private final class AnsweredOnce<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Value) -> Void)?

    init(_ completion: @escaping @Sendable (Value) -> Void) {
        self.completion = completion
    }

    func finish(_ value: Value) {
        lock.lock()
        let pending = completion
        completion = nil
        lock.unlock()
        pending?(value)
    }
}
