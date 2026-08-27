import Foundation
import WetoCore

/// Ответ границы целиком: тело, код и время.
///
/// Раньше отсюда возвращалось одно тело, и журналу нечего было сказать про отказ:
/// «сервис не ответил» — это и таймаут, и 429, и страница-заглушка провайдера
/// с кодом 200. Различать их по разобранному ответу нельзя, потому что до разбора
/// дело и не доходит.
public struct HTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public let duration: TimeInterval

    public init(data: Data, statusCode: Int, duration: TimeInterval) {
        self.data = data
        self.statusCode = statusCode
        self.duration = duration
    }
}

public protocol HTTPFetching: Sendable {
    func fetch(from url: URL, headers: [String: String]) async throws -> HTTPResponse
}

/// Отказ по коду ответа несёт с собой сам ответ.
///
/// Тело у 429 и 403 обычно и объясняет отказ — «rate limit exceeded», имя
/// провайдера, требование капчи. Выбрасывая один код, журнал терял ровно то,
/// ради чего его читают.
public struct HTTPFetchError: LocalizedError {
    public let statusCode: Int
    public let response: HTTPResponse

    public init(statusCode: Int, response: HTTPResponse) {
        self.statusCode = statusCode
        self.response = response
    }

    public var errorDescription: String? { "HTTP \(statusCode)" }
}

public struct URLSessionHTTPFetcher: HTTPFetching {

    private let session: URLSession

    public init(timeout: TimeInterval = Constants.geoRequestTimeoutSeconds) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: configuration)
    }

    public func fetch(from url: URL, headers: [String: String]) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Часы монотонные: системное время умеет прыгать, а длительность запроса
        // в журнале не должна становиться отрицательной от перевода часов.
        let started = ContinuousClock.now
        let (data, response) = try await session.data(for: request)
        let elapsed = ContinuousClock.now - started
        let duration = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let answer = HTTPResponse(data: data, statusCode: status, duration: duration)
        if !(200..<300).contains(status) {
            throw HTTPFetchError(statusCode: status, response: answer)
        }
        return answer
    }
}
