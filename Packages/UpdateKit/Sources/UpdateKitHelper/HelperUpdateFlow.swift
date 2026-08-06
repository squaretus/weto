import Foundation
import UpdateKitCore

/// Порядок действий демона: перепроверить релиз → ответить клиенту → скачать →
/// поставить → запомнить провал. Проверка релиза, скачивание и установка приходят
/// границами: настоящие ходят в сеть и запускают installer, тестовые — нет.
public struct HelperUpdateFlow: Sendable {

    public typealias ReleaseChecking =
        @Sendable (String, @escaping @Sendable (Result<UpdateInfo, Error>) -> Void) -> Void
    public typealias Downloading = @Sendable (
        String,
        @escaping @Sendable (Double) -> Void,
        @escaping @Sendable (Result<String, Error>) -> Void
    ) -> Void
    public typealias Installing = @Sendable (String) throws -> Void

    private let configuration: UpdateFeedConfiguration
    private let state: HelperInstallState
    private let checkRelease: ReleaseChecking
    private let download: Downloading
    private let install: Installing

    public init(
        configuration: UpdateFeedConfiguration,
        state: HelperInstallState,
        checkRelease: @escaping ReleaseChecking,
        download: @escaping Downloading,
        install: @escaping Installing
    ) {
        self.configuration = configuration
        self.state = state
        self.checkRelease = checkRelease
        self.download = download
        self.install = install
    }

    public func start(
        currentVersion: String?,
        reply: @escaping @Sendable (String?) -> Void
    ) {
        guard state.begin() else {
            reply("Установка уже идёт")
            return
        }

        // Подставлять «0.0.0» нельзя: тогда любой релиз оказывается новее
        // и демон под root ставит пакет на пустом основании.
        guard let currentVersion else {
            state.finish(failure: nil)
            reply("Не удалось прочитать версию установленного приложения")
            return
        }

        checkRelease(currentVersion) { result in
            switch result {
            case .failure(let error):
                state.finish(failure: nil)
                reply(error.localizedDescription)

            case .success(let info):
                guard info.isNewer else {
                    state.finish(failure: nil)
                    reply("Обновления нет: установлена \(info.currentVersion)")
                    return
                }
                guard !info.downloadURL.isEmpty else {
                    state.finish(failure: nil)
                    reply("В релизе нет файла \(configuration.assetSuffix)")
                    return
                }

                // Клиенту отвечаем сразу: скачивание и установка идут дальше сами,
                // а установщик по ходу выгрузит и этот демон.
                reply(nil)
                downloadAndInstall(info)
            }
        }
    }

    private func downloadAndInstall(_ info: UpdateInfo) {
        download(
            info.downloadURL,
            { fraction in state.report(fraction: fraction) },
            { result in
                switch result {
                case .failure(let error):
                    state.finish(failure: "Не удалось скачать пакет: \(error.localizedDescription)")

                case .success(let path):
                    state.beginInstalling()
                    do {
                        try install(path)
                        state.finish(failure: nil)
                    } catch {
                        state.finish(failure: "Установка не удалась: \(error.localizedDescription)")
                    }
                }
            }
        )
    }
}
