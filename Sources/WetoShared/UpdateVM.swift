import Foundation
import Observation
import AppKit
import WetoCore
import WetoSystem

@Observable
@MainActor
public final class UpdateVM {

    public enum State: Equatable, Sendable {
        case idle
        case checking
        case upToDate(String)
        case available(UpdateInfo)

        case noReleases
        case failed(String)
    }

    public private(set) var state: State = .idle

    @ObservationIgnored private let fetcher: HTTPFetching
    @ObservationIgnored private var checkTask: Task<Void, Never>?

    public init(fetcher: HTTPFetching = URLSessionHTTPFetcher(timeout: 15)) {
        self.fetcher = fetcher
    }

    deinit { checkTask?.cancel() }

    public func checkForUpdate() {
        guard state != .checking else { return }
        state = .checking

        checkTask?.cancel()
        checkTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.fetchLatest()
            await MainActor.run { self.state = result }
        }
    }

    public func startPeriodicCheck() {
        checkForUpdate()
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Constants.updateCheckInterval))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.checkForUpdate() }
            }
        }
    }

    public func openReleasePage() {
        guard case .available(let info) = state,
              let url = URL(string: info.releaseURL)
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func fetchLatest() async -> State {
        guard let url = URL(string: ReleaseParser.latestReleaseURL) else {
            return .failed("Некорректный адрес репозитория")
        }
        do {
            let data = try await fetcher.data(
                from: url,
                headers: ["Accept": "application/vnd.github+json"]
            )
            let info = try ReleaseParser.parse(data, currentVersion: Constants.appVersion).get()
            return info.isNewer ? .available(info) : .upToDate(info.currentVersion)
        } catch HTTPFetchError.badStatus(404) {
            return .noReleases
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
