import Foundation
import UpdateKitCore

/// Собственный запрос демона к источнику релизов. Демон не верит клиенту:
/// ни ссылка, ни версия к нему извне не приходят.
public struct ReleaseChecker: Sendable {

    private let configuration: UpdateFeedConfiguration

    public init(configuration: UpdateFeedConfiguration) {
        self.configuration = configuration
    }

    public func checkLatestRelease(
        currentVersion: String,
        completion: @escaping @Sendable (Result<UpdateInfo, Error>) -> Void
    ) {
        guard let url = URL(string: configuration.latestReleaseURL) else {
            completion(.failure(HelperError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let configuration = self.configuration
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                completion(.failure(HelperError.httpError(http.statusCode)))
                return
            }
            guard let data else {
                completion(.failure(HelperError.emptyResponse))
                return
            }
            completion(ReleaseParser.parse(
                data,
                currentVersion: currentVersion,
                configuration: configuration
            ))
        }.resume()
    }
}
