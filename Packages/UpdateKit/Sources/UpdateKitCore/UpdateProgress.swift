import Foundation

/// Фаза установки. Сырые значения зафиксированы: они ходят через XPC числом.
public enum UpdatePhase: Int, Equatable, Sendable {
    case idle = 0
    case checking = 1
    case downloading = 2
    case installing = 3
    case failed = 4
}

/// Ход установки, каким его видит приложение. `installer` прогресса не отдаёт,
/// поэтому доля значима только на фазе загрузки — на установке полоса честно
/// неопределённая, а не поддельная.
public struct UpdateProgress: Equatable, Sendable {

    public let phase: UpdatePhase
    public let fraction: Double
    public let failure: String?

    public static let idle = UpdateProgress(phase: .idle)

    public init(phase: UpdatePhase, fraction: Double = 0, failure: String? = nil) {
        self.phase = phase
        self.fraction = min(max(fraction, 0), 1)
        self.failure = failure
    }

    public var isInFlight: Bool {
        switch phase {
        case .checking, .downloading, .installing: return true
        case .idle, .failed: return false
        }
    }

    /// Через границу демона ходят только числа и строка: маршалить новые классы
    /// не нужно, а разбор ответа проверяется без живого демона.
    public var xpc: (phase: Int, fraction: Double, failure: String?) {
        (phase.rawValue, fraction, failure)
    }

    public static func fromXPC(phase: Int, fraction: Double, failure: String?) -> UpdateProgress {
        guard let known = UpdatePhase(rawValue: phase) else {
            // Демон старой версии не знает о фазах. Считать его ответ простоем
            // нельзя: установка идёт, и спиннер обязан остаться.
            return UpdateProgress(phase: .installing)
        }
        return UpdateProgress(phase: known, fraction: fraction, failure: failure)
    }
}
