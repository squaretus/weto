import Foundation

/// Запрос последнего релиза по HTTP. Кэш выключен: ответ о новой версии,
/// взятый из кэша, — это ровно то, чего механизм обновления не должен показывать.
public struct URLSessionReleaseFetcher: ReleaseFetching {

    private let session: URLSession

    public init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: configuration)
    }

    public func latestRelease(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ReleaseFetchError.badStatus(http.statusCode)
        }
        return data
    }
}
