import Foundation
import WetoCore
import UpdateKitCore
import UpdateKitXPC

/// Установка обновления как граница системы: за протоколом, чтобы поведение
/// приложения проверялось без живого root-демона.
public protocol UpdateInstalling: Sendable {
    /// `nil` в ответе означает, что демон недоступен: не установлен, не загружен
    /// или отказал в соединении. Это не ошибка установки, а отсутствие механизма.
    func requestInstall(completion: @escaping @Sendable (UpdaterService.InstallResult?) -> Void)

    /// Ход установки, о которой демон уже ответил «начата»: скачивание
    /// и `installer` идут после ответа. `nil` — демон не ответил; судит об этом
    /// вызывающий: молчание демона не провал и не успех.
    func requestProgress(completion: @escaping @Sendable (UpdateProgress?) -> Void)
}

/// Снятие демона при полном удалении приложения.
public protocol HelperUninstalling: Sendable {
    /// `nil` — демон снят или его и не было; строка — что именно не удалось.
    func uninstallHelper(completion: @escaping @Sendable (String?) -> Void)
}

public struct HelperUpdateInstaller: UpdateInstalling, HelperUninstalling {

    private let client: UpdaterXPCClient

    public init(configuration: UpdateFeedConfiguration = WetoUpdate.configuration) {
        self.client = UpdaterXPCClient(machServiceName: configuration.machServiceName)
    }

    public func requestInstall(
        completion: @escaping @Sendable (UpdaterService.InstallResult?) -> Void
    ) {
        // Одно и то же завершение может прийти и из errorHandler соединения,
        // и из ответа демона — пропускаем только первое.
        let answered = AnsweredOnce(completion)

        guard let helper = client.helper(errorHandler: { _ in answered.finish(nil) }) else {
            answered.finish(nil)
            return
        }

        UpdaterService.install(helper: helper) { result in
            answered.finish(result)
        }
    }

    public func requestProgress(completion: @escaping @Sendable (UpdateProgress?) -> Void) {
        let answered = AnsweredOnceProgress(completion)

        // Демон умирает вместе с установкой — молчание здесь нормально
        // и означает «сказать нечего», а не «сбой».
        guard let helper = client.helper(errorHandler: { _ in answered.finish(nil) }) else {
            answered.finish(nil)
            return
        }

        UpdaterService.state(helper: helper) { phase, fraction, failure in
            answered.finish(
                UpdateProgress.fromXPC(phase: phase, fraction: fraction, failure: failure)
            )
        }
    }

    public func uninstallHelper(completion: @escaping @Sendable (String?) -> Void) {
        let answered = AnsweredOnceString(completion)

        // Демона может не быть вовсе — это не ошибка удаления.
        guard let helper = client.helper(errorHandler: { _ in answered.finish(nil) }) else {
            answered.finish(nil)
            return
        }
        helper.uninstallHelper { failure in answered.finish(failure) }
    }
}

private final class AnsweredOnceString: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (String?) -> Void)?

    init(_ completion: @escaping @Sendable (String?) -> Void) {
        self.completion = completion
    }

    func finish(_ value: String?) {
        lock.lock()
        let pending = completion
        completion = nil
        lock.unlock()
        pending?(value)
    }
}

private final class AnsweredOnceProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (UpdateProgress?) -> Void)?

    init(_ completion: @escaping @Sendable (UpdateProgress?) -> Void) {
        self.completion = completion
    }

    func finish(_ value: UpdateProgress?) {
        lock.lock()
        let pending = completion
        completion = nil
        lock.unlock()
        pending?(value)
    }
}

private final class AnsweredOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (UpdaterService.InstallResult?) -> Void)?

    init(_ completion: @escaping @Sendable (UpdaterService.InstallResult?) -> Void) {
        self.completion = completion
    }

    func finish(_ result: UpdaterService.InstallResult?) {
        lock.lock()
        let pending = completion
        completion = nil
        lock.unlock()
        pending?(result)
    }
}
