import Foundation
import Observation
import AppKit
import WetoCore
import WetoSystem
import WetoXPC

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

    /// Установка идёт прямо сейчас: демон принял запрос и качает пакет.
    /// Приложение при успешной установке погибнет — установщик выгружает и его,
    /// и демон, поэтому снимать флаг обычно не приходится.
    public private(set) var isInstallingUpdate = false

    /// Почему установка не пошла. Пустое значение — нечего показывать.
    public private(set) var installFailure: String?

    /// Найденное обновление, пригодное для показа где угодно в UI: в попапе менюбара
    /// и в окне настроек. Раньше о нём знал только футер настроек, и увидеть новость
    /// можно было, лишь открыв настройки.
    public var availableUpdate: UpdateInfo? {
        guard case .available(let info) = state, info.isNewer else { return nil }
        return info
    }

    @ObservationIgnored private let fetcher: HTTPFetching
    @ObservationIgnored private let opener: URLOpening
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?

    @ObservationIgnored private let currentVersion: String
    @ObservationIgnored private let installer: UpdateInstalling

    public init(
        fetcher: HTTPFetching = URLSessionHTTPFetcher(timeout: 15),
        opener: URLOpening = SystemURLOpener(),
        installer: UpdateInstalling = HelperUpdateInstaller(),
        currentVersion: String = Constants.appVersion
    ) {
        self.fetcher = fetcher
        self.opener = opener
        self.installer = installer
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

    /// Одна кнопка на два действия: когда обновление найдено — поставить его,
    /// в остальных состояниях — проверить заново.
    public func primaryAction() {
        guard availableUpdate != nil else {
            checkForUpdate()
            return
        }
        installUpdate()
    }

    /// Просит демон скачать и установить обновление. Демон не получает от нас
    /// ни ссылки, ни версии — он перепроверяет релиз сам.
    public func installUpdate() {
        guard let update = availableUpdate, !isInstallingUpdate else { return }

        isInstallingUpdate = true
        installFailure = nil

        installer.requestInstall { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .started:
                    break // Ждём: установщик выгрузит приложение сам.
                case .failed(let message):
                    self.isInstallingUpdate = false
                    self.installFailure = message
                case nil:
                    // Демона нет — честно говорим об этом и оставляем ручной путь.
                    self.isInstallingUpdate = false
                    self.installFailure = "Служба обновления недоступна — откройте страницу релиза"
                    if let url = Self.validatedReleaseURL(update.releaseURL) {
                        self.opener.open(url)
                    }
                }
            }
        }
    }

    public func openReleasePage() {
        guard let update = availableUpdate,
              let url = Self.validatedReleaseURL(update.releaseURL)
        else { return }
        opener.open(url)
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
