import Foundation
import WetoCore

/// Проверка релиза и установка PKG. Живёт в демоне, потому что `installer`
/// требует root, а скачанный пакет до установки не должен быть доступен
/// пользовательским процессам на запись.
enum UpdateChecker {

    enum UpdateError: LocalizedError, Equatable {
        case invalidURL
        case httpError(Int)
        case emptyResponse
        case noPackage
        case downloadFailed(String)
        case installFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Некорректный URL"
            case .httpError(let code): return "GitHub ответил HTTP \(code)"
            case .emptyResponse: return "Пустой ответ GitHub"
            case .noPackage: return "В релизе нет файла .pkg"
            case .downloadFailed(let reason): return "Не удалось скачать пакет: \(reason)"
            case .installFailed(let code): return "Установщик завершился с кодом \(code)"
            }
        }
    }

    /// Каталог для скачанного пакета: создаётся под root с правами 0700, файл — 0600.
    /// Через `/tmp` идти нельзя — между скачиванием и `installer -pkg` пакет можно
    /// подменить из пользовательского процесса, и root установил бы чужое.
    static let updatesDirectory = "/var/db/weto/updates"
    static let packagePath = "\(updatesDirectory)/weto-update.pkg"

    // MARK: - Проверка

    static func checkLatestRelease(
        currentVersion: String,
        completion: @escaping @Sendable (Result<UpdateInfo, Error>) -> Void
    ) {
        guard let url = URL(string: ReleaseParser.latestReleaseURL) else {
            completion(.failure(UpdateError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                completion(.failure(UpdateError.httpError(http.statusCode)))
                return
            }
            guard let data else {
                completion(.failure(UpdateError.emptyResponse))
                return
            }
            completion(ReleaseParser.parse(data, currentVersion: currentVersion))
        }.resume()
    }

    // MARK: - Скачивание

    static func ensureUpdatesDirectory() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: updatesDirectory) {
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: updatesDirectory)
        } else {
            try manager.createDirectory(
                at: URL(fileURLWithPath: updatesDirectory),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    static func downloadPackage(
        from string: String,
        completion: @escaping @Sendable (Result<String, Error>) -> Void
    ) {
        guard ReleasePackageURL.isTrusted(string), let url = URL(string: string) else {
            completion(.failure(UpdateError.invalidURL))
            return
        }

        do {
            try ensureUpdatesDirectory()
        } catch {
            completion(.failure(UpdateError.downloadFailed(error.localizedDescription)))
            return
        }

        try? FileManager.default.removeItem(atPath: packagePath)

        URLSession.shared.downloadTask(with: url) { temporary, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                completion(.failure(UpdateError.httpError(http.statusCode)))
                return
            }
            guard let temporary else {
                completion(.failure(UpdateError.downloadFailed("нет временного файла")))
                return
            }

            do {
                try FileManager.default.moveItem(
                    at: temporary,
                    to: URL(fileURLWithPath: packagePath)
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: packagePath
                )
                completion(.success(packagePath))
            } catch {
                completion(.failure(UpdateError.downloadFailed(error.localizedDescription)))
            }
        }.resume()
    }

    // MARK: - Установка

    static func installPackage(atPath path: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/installer")
        process.arguments = ["-pkg", path, "-target", "/"]

        try process.run()
        process.waitUntilExit()

        let status = process.terminationStatus
        // Пакет удаляется независимо от исхода: он больше не нужен и лежит под root.
        try? FileManager.default.removeItem(atPath: path)

        guard status == 0 else { throw UpdateError.installFailed(status) }
    }
}
