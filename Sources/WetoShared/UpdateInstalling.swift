import Foundation
import WetoCore
import WetoXPC

/// Установка обновления как граница системы: за протоколом, чтобы поведение
/// приложения проверялось без живого root-демона.
public protocol UpdateInstalling: Sendable {
    /// `nil` в ответе означает, что демон недоступен: не установлен, не загружен
    /// или отказал в соединении. Это не ошибка установки, а отсутствие механизма.
    func requestInstall(completion: @escaping @Sendable (UpdateService.InstallResult?) -> Void)

    /// Провал установки, о которой демон уже ответил «начата»: скачивание
    /// и `installer` идут после ответа, и без этого запроса их отказ виден
    /// только в unified log.
    func requestLastFailure(completion: @escaping @Sendable (String?) -> Void)
}

/// Снятие демона при полном удалении приложения.
public protocol HelperUninstalling: Sendable {
    /// `nil` — демон снят или его и не было; строка — что именно не удалось.
    func uninstallHelper(completion: @escaping @Sendable (String?) -> Void)
}

public struct HelperUpdateInstaller: UpdateInstalling, HelperUninstalling {

    private let client = WetoXPCClient()

    public init() {}

    public func requestInstall(
        completion: @escaping @Sendable (UpdateService.InstallResult?) -> Void
    ) {
        // Одно и то же завершение может прийти и из errorHandler соединения,
        // и из ответа демона — пропускаем только первое.
        let answered = AnsweredOnce(completion)

        guard let helper = client.helper(errorHandler: { _ in answered.finish(nil) }) else {
            answered.finish(nil)
            return
        }

        UpdateService.install(helper: helper) { result in
            answered.finish(result)
        }
    }

    public func requestLastFailure(completion: @escaping @Sendable (String?) -> Void) {
        let answered = AnsweredOnceString(completion)

        // Демон умирает вместе с установкой — молчание здесь нормально
        // и означает «сказать нечего», а не «сбой».
        guard let helper = client.helper(errorHandler: { _ in answered.finish(nil) }) else {
            answered.finish(nil)
            return
        }

        UpdateService.lastFailure(helper: helper) { failure in answered.finish(failure) }
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

private final class AnsweredOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (UpdateService.InstallResult?) -> Void)?

    init(_ completion: @escaping @Sendable (UpdateService.InstallResult?) -> Void) {
        self.completion = completion
    }

    func finish(_ result: UpdateService.InstallResult?) {
        lock.lock()
        let pending = completion
        completion = nil
        lock.unlock()
        pending?(result)
    }
}
