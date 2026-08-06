import Foundation

/// Ошибки, которые демон умеет объяснить клиенту словами.
public enum HelperError: LocalizedError, Equatable {
    case invalidURL
    case httpError(Int)
    case emptyResponse
    case noPackage(String)
    case downloadFailed(String)
    case installFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Некорректный URL"
        case .httpError(let code): return "GitHub ответил HTTP \(code)"
        case .emptyResponse: return "Пустой ответ GitHub"
        case .noPackage(let suffix): return "В релизе нет файла \(suffix)"
        case .downloadFailed(let reason): return "Не удалось скачать пакет: \(reason)"
        case .installFailed(let code): return "Установщик завершился с кодом \(code)"
        }
    }
}
