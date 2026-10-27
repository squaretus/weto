import Darwin
import Foundation

/// Секреты файлами с правами `0600` — для терминальной версии.
///
/// Связка ключей у фонового сервиса не годится: при первом же чтении после
/// пересборки бинарника она спрашивает разрешения диалогом, а показать его
/// заданию launchd или сеансу по ssh некому, и охрана осталась бы без токена.
/// Файл лежит в каталоге данных CLI, а не рядом с настройками: plist настроек
/// читает любой процесс пользователя, и он уходит в бэкапы.
public struct FileSecretStore: SecretStoring {

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Имя файла — имя учётной записи: `token` у ipinfo.
    public func url(account: String) -> URL {
        directory.appendingPathComponent(account)
    }

    public func read(account: String) -> String? {
        guard let data = FileManager.default.contents(atPath: url(account: account).path),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public func write(_ value: String?, account: String) -> Result<Void, SecretStoreError> {
        let target = url(account: account)

        guard let value, !value.isEmpty else {
            guard FileManager.default.fileExists(atPath: target.path) else { return .success(()) }
            do {
                try FileManager.default.removeItem(at: target)
                return .success(())
            } catch {
                return .failure(.file(error.localizedDescription))
            }
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure(.file(error.localizedDescription))
        }

        // Права ставятся при создании, а не после записи: между записью и `chmod`
        // токен лежал бы открытым для всех. Временный файл и переименование —
        // чтобы прерванная запись не оставила половину токена.
        let temporary = target.appendingPathExtension("tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard descriptor >= 0 else { return .failure(.file(String(cString: strerror(errno)))) }
        // Файл, оставшийся от прошлого раза с другими правами, `open` не трогает.
        fchmod(descriptor, 0o600)

        let bytes = Array(value.utf8)
        let written = bytes.withUnsafeBufferPointer { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        let writeError = written == bytes.count ? nil : String(cString: strerror(errno))
        close(descriptor)
        if let writeError {
            unlink(temporary.path)
            return .failure(.file(writeError))
        }
        guard rename(temporary.path, target.path) == 0 else {
            let detail = String(cString: strerror(errno))
            unlink(temporary.path)
            return .failure(.file(detail))
        }
        return .success(())
    }
}
