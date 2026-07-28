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
    @ObservationIgnored private let opener: URLOpening
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?

    @ObservationIgnored private let currentVersion: String

    public init(
        fetcher: HTTPFetching = URLSessionHTTPFetcher(timeout: 15),
        opener: URLOpening = SystemURLOpener(),
        currentVersion: String = Constants.appVersion
    ) {
        self.fetcher = fetcher
        self.opener = opener
        self.currentVersion = currentVersion
    }

    deinit {
        checkTask?.cancel()
        periodicTask?.cancel()
    }

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

    /// Периодическая проверка запускается один раз: прежняя реализация создавала
    /// новый неотменяемый цикл на каждый вызов.
    public func startPeriodicCheck() {
        guard periodicTask == nil else { return }
        checkForUpdate()

        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Constants.updateCheckInterval))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.checkForUpdate() }
            }
        }
    }

    public func stop() {
        periodicTask?.cancel(); periodicTask = nil
        checkTask?.cancel(); checkTask = nil
    }

    /// Одна кнопка на два действия: когда обновление найдено — открыть релиз,
    /// в остальных состояниях — проверить заново. Прежде страницу релиза
    /// нельзя было открыть вообще: кнопка всегда только перепроверяла.
    public func primaryAction() {
        if case .available(let info) = state, let url = Self.validatedReleaseURL(info.releaseURL) {
            opener.open(url)
            return
        }
        checkForUpdate()
    }

    public func checkForUpdateAndWait() async {
        checkForUpdate()
        await checkTask?.value
    }

    /// Открываем только https-ссылку на github.com: адрес приходит из сети.
    static func validatedReleaseURL(_ string: String) -> URL? {
        guard let url = URL(string: string),
              url.scheme == "https",
              url.host == "github.com"
        else { return nil }
        return url
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
            let info = try ReleaseParser.parse(data, currentVersion: currentVersion).get()
            return info.isNewer ? .available(info) : .upToDate(info.currentVersion)
        } catch HTTPFetchError.badStatus(404) {
            return .noReleases
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
