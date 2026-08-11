import Foundation
import WetoCore

public protocol HTTPFetching: Sendable {
    func data(from url: URL, headers: [String: String]) async throws -> Data
}

public enum HTTPFetchError: LocalizedError {
    case badStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "HTTP \(code)"
        }
    }
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

    public func data(from url: URL, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPFetchError.badStatus(http.statusCode)
        }
        return data
    }
}
