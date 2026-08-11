import Foundation
import Observation
import UpdateKitCore
import UpdateKitXPC

/// Механизм обновления целиком: проверка, решение о показе, установка и её ход.
/// Ничего не знает ни об AppKit, ни о SwiftUI — окно подписывается на него само.
@Observable
@MainActor
public final class UpdateController {

    public enum State: Equatable, Sendable {
        case idle
        case checking
        case upToDate(String)
        case available(UpdateInfo)
        case noReleases
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var progress: UpdateProgress = .idle
    public private(set) var isDialogPresented = false

    /// Тумблер автообновления. Один и тот же для окна и для настроек: пишет
    /// в то же хранилище и немедленно запускает установку найденного обновления —
    /// иначе настройка не делает того, ради чего её включают.
    public var isAutoInstallEnabled: Bool {
        get { deferral.isAutoInstallEnabled }
        set {
            deferral.isAutoInstallEnabled = newValue
            store.save(deferral)
            if newValue, availableUpdate != nil { install() }
        }
    }

    /// Обновление, о котором есть смысл говорить в UI.
    public var availableUpdate: UpdateInfo? {
        guard case .available(let info) = state, info.isNewer else { return nil }
        return info
    }

    /// То же самое, но с учётом молчания: пропущенная и отложенная версии
    /// не показываются и в баннере.
    public var bannerUpdate: UpdateInfo? {
        guard let update = availableUpdate else { return nil }
        guard progress.isInFlight || isDialogPresented || lastOutcome != .silent else { return nil }
        return update
    }

    public var dialogModel: UpdateDialogModel {
        UpdateDialogModel.make(info: availableUpdate, progress: progress, strings: strings)
    }

    /// Презентер окна подписывается сюда: контроллер не знает, чем именно
    /// показывается окно, и переносится в проект без своего UI.
    @ObservationIgnored public var presentationHandler: (@MainActor (Bool) -> Void)?

    @ObservationIgnored public let strings: UpdateStrings
    @ObservationIgnored private let configuration: UpdateFeedConfiguration
    @ObservationIgnored private let currentVersion: String
    @ObservationIgnored private let fetcher: ReleaseFetching
    @ObservationIgnored private let installer: UpdateInstalling
    @ObservationIgnored private let store: UpdateStateStoring
    @ObservationIgnored private let clock: UpdateClock
    @ObservationIgnored private let opener: URLOpening

    @ObservationIgnored private var deferral: UpdateDeferral
    @ObservationIgnored private var lastOutcome: UpdatePolicy.Outcome = .silent
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    @ObservationIgnored private var progressTask: Task<Void, Never>?

    public init(
        configuration: UpdateFeedConfiguration,
        strings: UpdateStrings,
        currentVersion: String,
        fetcher: ReleaseFetching,
        installer: UpdateInstalling,
        store: UpdateStateStoring,
        clock: UpdateClock = SystemClock(),
        opener: URLOpening
    ) {
        self.configuration = configuration
        self.strings = strings
        self.currentVersion = currentVersion
        self.fetcher = fetcher
        self.installer = installer
        self.store = store
        self.clock = clock
        self.opener = opener
        self.deferral = store.loadDeferral()
    }

    deinit {
        checkTask?.cancel()
        periodicTask?.cancel()
        progressTask?.cancel()
    }

    // MARK: - Проверка

    /// Проверка на старте и часовой цикл. Запускается один раз: иначе каждый
    /// вызов заводил бы новый неотменяемый цикл.
    public func start() {
        guard periodicTask == nil else { return }
        check(isManual: false)

        periodicTask = Task { [weak self, interval = configuration.checkInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.check(isManual: false) }
            }
        }
    }

    public func stop() {
        periodicTask?.cancel(); periodicTask = nil
        checkTask?.cancel(); checkTask = nil
        progressTask?.cancel(); progressTask = nil
    }

    /// Проверка по кнопке: пропуск и отложенное напоминание игнорируются,
    /// окно показывается всегда. Это единственный способ вернуть пропущенную версию.
    public func checkNow() {
        check(isManual: true)
    }

    private func check(isManual: Bool) {
        guard state != .checking else { return }
        state = .checking

        checkTask?.cancel()
        checkTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.fetchLatest()
            await MainActor.run {
                self.state = result
                self.store.saveLastCheck(self.clock.now)
                self.apply(isManual: isManual)
            }
        }
    }

    private func apply(isManual: Bool) {
        guard let update = availableUpdate else {
            lastOutcome = .silent
            return
        }

        let outcome: UpdatePolicy.Outcome = isManual
            ? .prompt
            : UpdatePolicy.decide(latest: update, deferral: deferral, now: clock.now)
        lastOutcome = outcome

        switch outcome {
        case .silent:
            break
        case .prompt:
            presentDialog()
        case .install:
            install()
        }
    }

    private func fetchLatest() async -> State {
        guard let url = URL(string: configuration.latestReleaseURL) else {
            return .failed("Некорректный адрес репозитория")
        }
        do {
            let data = try await fetcher.latestRelease(from: url)
            let info = try ReleaseParser.parse(
                data,
                currentVersion: currentVersion,
                configuration: configuration
            ).get()
            return info.isNewer ? .available(info) : .upToDate(info.currentVersion)
        } catch ReleaseFetchError.badStatus(404) {
            return .noReleases
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Решения пользователя

    public func presentDialog() {
        guard availableUpdate != nil else { return }
        isDialogPresented = true
        presentationHandler?(true)
    }

    public func skipCurrentVersion() {
        deferral.skippedVersion = availableUpdate?.latestVersion
        store.save(deferral)
        closeDialog()
    }

    public func remindLater(_ interval: RemindInterval) {
        deferral.remindAt = clock.now.addingTimeInterval(interval.rawValue)
        store.save(deferral)
        closeDialog()
    }

    /// Закрытие окна крестиком: молчаливое закрытие не должно означать
    /// «больше никогда».
    public func dismissDialog() {
        remindLater(.threeHours)
    }

    private func closeDialog() {
        lastOutcome = .silent
        isDialogPresented = false
        presentationHandler?(false)
    }

    // MARK: - Установка

    public func install() {
        guard let update = availableUpdate, !progress.isInFlight else { return }

        // Релиз без пакета демон установить не может: просить root начинать нечего.
        guard !update.downloadURL.isEmpty else {
            progress = UpdateProgress(phase: .failed, failure: strings.noPackage)
            openReleasePage()
            return
        }

        progress = UpdateProgress(phase: .checking)

        installer.requestInstall { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .started:
                    // Ждём: при успехе установщик выгрузит приложение сам,
                    // а ход установки виден только через опрос демона.
                    self.startPollingProgress()
                case .failed(let message):
                    self.progress = UpdateProgress(phase: .failed, failure: message)
                case nil:
                    // Демона нет — честно говорим об этом и оставляем ручной путь.
                    self.progress = UpdateProgress(phase: .failed, failure: self.strings.noDaemon)
                    self.openReleasePage()
                }
            }
        }
    }

    private func startPollingProgress() {
        progressTask?.cancel()
        progressTask = Task { [weak self, interval = configuration.progressPollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.pollProgressOnce() }
            }
        }
    }

    /// Один опрос демона. При успехе установщик завершает приложение сам —
    /// этот опрос существует ради прогресса и провала.
    func pollProgressOnce() {
        guard progress.isInFlight else { return }

        installer.requestProgress { [weak self] reported in
            Task { @MainActor [weak self] in
                guard let self, self.progress.isInFlight else { return }
                // Молчание демона — не успех: состояние не трогаем.
                guard let reported, reported.phase != .idle else { return }
                self.progress = reported
                if !reported.isInFlight {
                    self.progressTask?.cancel()
                    self.progressTask = nil
                }
            }
        }
    }

    public func openReleasePage() {
        let address = availableUpdate?.releaseURL ?? configuration.releasesPageURL
        guard let url = Self.validatedReleaseURL(address) else { return }
        opener.open(url)
    }

    /// Открываем только https-ссылку на github.com: адрес приходит из сети.
    static func validatedReleaseURL(_ string: String) -> URL? {
        guard let url = URL(string: string),
              url.scheme == "https",
              url.host == "github.com"
        else { return nil }
        return url
    }

    // MARK: - Для тестов

    func checkAndWait() async {
        check(isManual: false)
        await checkTask?.value
    }

    func checkNowAndWait() async {
        check(isManual: true)
        await checkTask?.value
    }
}
