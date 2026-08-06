import Foundation
import UpdateKitCore

/// Скачивание пакета под root с отчётом о доле. Делегат нужен именно ради доли:
/// вариант с завершением её не отдаёт, и полосу в окне рисовать было бы нечем.
public final class PackageDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let configuration: UpdateFeedConfiguration
    private let lock = NSLock()
    private var onProgress: (@Sendable (Double) -> Void)?
    private var completion: (@Sendable (Result<String, Error>) -> Void)?
    private lazy var session = URLSession(
        configuration: .ephemeral,
        delegate: self,
        delegateQueue: nil
    )

    public init(configuration: UpdateFeedConfiguration) {
        self.configuration = configuration
        super.init()
    }

    public func download(
        from string: String,
        onProgress: @escaping @Sendable (Double) -> Void,
        completion: @escaping @Sendable (Result<String, Error>) -> Void
    ) {
        // Адрес приходит из сети: подставлять его в загрузчик без проверки нельзя —
        // подменённый ответ увёл бы установку на чужой файл.
        guard ReleasePackageURL.isTrusted(string), let url = URL(string: string) else {
            completion(.failure(HelperError.invalidURL))
            return
        }

        do {
            try prepareWorkingDirectory()
        } catch {
            completion(.failure(HelperError.downloadFailed(error.localizedDescription)))
            return
        }

        try? FileManager.default.removeItem(atPath: configuration.packagePath)

        lock.lock()
        self.onProgress = onProgress
        self.completion = completion
        lock.unlock()

        session.downloadTask(with: url).resume()
    }

    // MARK: - URLSessionDownloadDelegate

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        lock.lock(); let report = onProgress; lock.unlock()
        report?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(.failure(HelperError.httpError(http.statusCode)))
            return
        }

        do {
            let destination = URL(fileURLWithPath: configuration.packagePath)
            try FileManager.default.moveItem(at: location, to: destination)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: destination.path
            )
            finish(.success(destination.path))
        } catch {
            finish(.failure(HelperError.downloadFailed(error.localizedDescription)))
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        finish(.failure(error))
    }

    // MARK: - Внутреннее

    /// Каталог под root с правами 0700: через /tmp идти нельзя — между скачиванием
    /// и `installer -pkg` пакет можно подменить из пользовательского процесса.
    private func prepareWorkingDirectory() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: configuration.workingDirectory) {
            try manager.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: configuration.workingDirectory
            )
        } else {
            try manager.createDirectory(
                at: URL(fileURLWithPath: configuration.workingDirectory),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    /// Ответ уходит один раз: `didCompleteWithError` приходит и после
    /// успешного `didFinishDownloadingTo`.
    private func finish(_ result: Result<String, Error>) {
        lock.lock()
        let pending = completion
        completion = nil
        onProgress = nil
        lock.unlock()
        pending?(result)
    }
}

/// Установка пакета. Отдельный тип, потому что это единственное место,
/// запускающее внешний процесс под root.
public struct PackageInstaller: Sendable {

    public init() {}

    public func install(atPath path: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/installer")
        process.arguments = ["-pkg", path, "-target", "/"]

        try process.run()
        process.waitUntilExit()

        let status = process.terminationStatus
        // Пакет удаляется независимо от исхода: он больше не нужен и лежит под root.
        try? FileManager.default.removeItem(atPath: path)

        guard status == 0 else { throw HelperError.installFailed(status) }
    }
}
