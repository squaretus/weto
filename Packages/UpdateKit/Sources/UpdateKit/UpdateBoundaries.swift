import Foundation
import UpdateKitCore
import UpdateKitXPC

/// Запрос релиза — граница системы: в тестах подменяется, чтобы поведение
/// проверялось без сети.
public protocol ReleaseFetching: Sendable {
    func latestRelease(from url: URL) async throws -> Data
}

public enum ReleaseFetchError: LocalizedError, Equatable {
    case badStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "HTTP \(code)"
        }
    }
}

/// Установка обновления — граница системы: за протоколом, чтобы поведение
/// приложения проверялось без живого root-демона.
public protocol UpdateInstalling: Sendable {
    /// `nil` — демон недоступен: не установлен, не загружен или отказал
    /// в соединении. Это не ошибка установки, а отсутствие механизма.
    func requestInstall(completion: @escaping @Sendable (UpdaterService.InstallResult?) -> Void)

    /// `nil` — демон не ответил. Судит об этом вызывающий: молчание демона
    /// не успех и не провал.
    func requestProgress(completion: @escaping @Sendable (UpdateProgress?) -> Void)
}

/// Снятие демона при полном удалении приложения.
public protocol HelperUninstalling: Sendable {
    /// `nil` — демон снят или его и не было; строка — что именно не удалось.
    func uninstallHelper(completion: @escaping @Sendable (String?) -> Void)
}

/// Хранилище решений пользователя. Живёт на главном акторе вместе с контроллером.
@MainActor
public protocol UpdateStateStoring {
    func loadDeferral() -> UpdateDeferral
    func save(_ deferral: UpdateDeferral)
    func loadLastCheck() -> Date?
    func saveLastCheck(_ date: Date)
}

/// Часы — граница: без них тесты отсрочки пришлось бы ждать по-настоящему.
public protocol UpdateClock: Sendable {
    var now: Date { get }
}

public struct SystemClock: UpdateClock {
    public init() {}
    public var now: Date { Date() }
}

/// Открытие внешней ссылки — граница: в тестах проверяется, какой именно адрес
/// уходит наружу. Реализация живёт в приложении: AppKit в пакет не тянем.
public protocol URLOpening: Sendable {
    func open(_ url: URL)
}
