import Foundation

/// Отчего гео-сервис не ответил — в терминах, понятных владельцу приложения.
///
/// Классификация живёт здесь, а не на границе: `WetoSystem` передаёт числа
/// (HTTP-статус, код `URLError`), а решение о формулировке остаётся чистой логикой.
public enum GeoFailure: Error, Equatable, Sendable {
    case noNetwork
    case unreachable
    case timedOut
    case unauthorized(Int)
    case rateLimited(Int)
    case serviceError(Int)

    /// Страховка: классификация промахнулась — показываем то, что сказала система.
    case other(String)

    public var displayText: String {
        switch self {
        case .noNetwork: return "нет сети"
        case .unreachable: return "сервис недоступен"
        case .timedOut: return "таймаут запроса"
        case .unauthorized(let status): return "токен отвергнут (\(status))"
        case .rateLimited(let status): return "лимит запросов (\(status))"
        case .serviceError(let status): return "сервис ответил ошибкой (\(status))"
        case .other(let text): return text
        }
    }
}

extension GeoFailure {
    public init(httpStatus: Int) {
        switch httpStatus {
        case 401, 403: self = .unauthorized(httpStatus)
        case 429: self = .rateLimited(httpStatus)
        default: self = .serviceError(httpStatus)
        }
    }

    public init(urlErrorCode: Int, description: String) {
        switch urlErrorCode {
        case -1009: self = .noNetwork
        case -1001: self = .timedOut
        case -1003, -1004, -1005, -1006: self = .unreachable
        default: self = .other(description)
        }
    }
}
