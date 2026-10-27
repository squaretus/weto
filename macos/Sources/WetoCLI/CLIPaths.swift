import Foundation

/// Где терминальная версия держит свои файлы. Всё отдельно от приложения:
/// окно настроек не должно увидеть туннель, а две установки — перепутать учёт
/// остановленных.
///
/// Мест два, и выбирает их эффективный uid, а не `$HOME`: `sudo` на macOS
/// сохраняет `HOME` пользователя, и по нему root писал бы в чужой каталог.
/// - пользовательское — `~/Library/Application Support/weto-cli/`, задание
///   `gui/<uid>/com.weto.cli` в `~/Library/LaunchAgents`;
/// - системное (euid 0) — `/Library/Application Support/weto/`, LaunchDaemon
///   `system/com.weto.cli` в `/Library/LaunchDaemons`.
struct CLIPaths: Equatable, Sendable {

    /// Набор настроек CLI. Тот же `SettingsStore`, но свой домен: в `com.weto.shared`
    /// лежат настройки приложения, и туннель туда попасть не должен. Имя одно
    /// на обе установки: системную от пользовательской отличает процесс root —
    /// `cfprefsd` разводит домены по euid.
    static let suiteName = "com.weto.cli"

    /// Задание launchd. Отдельное от `com.weto.app`: правило «автозапуск
    /// приложения — ровно один файл» его не касается.
    static let serviceLabel = "com.weto.cli"

    /// Каталог пользовательского хранилища — прежнее имя, раунд 2 его не меняет.
    static let userDirectoryName = "weto-cli"
    static let systemDirectoryName = "weto"

    /// Учётная запись токена в файловом хранилище — та же, что у `SettingsStore`.
    static let tokenAccount = "token"

    /// Системная установка: охрана всей машины от root.
    let isSystem: Bool
    /// Журналы, учёт остановленных, статус, замок и токен.
    let dataDirectory: URL
    /// Файл задания launchd: LaunchAgent пользователя или LaunchDaemon.
    let servicePlist: URL
    /// Куда launchd пишет stdout и stderr охраны.
    let logFile: URL

    static func user(home: URL) -> CLIPaths {
        CLIPaths(
            isSystem: false,
            dataDirectory: home.appendingPathComponent(
                "Library/Application Support/\(userDirectoryName)", isDirectory: true
            ),
            servicePlist: home.appendingPathComponent("Library/LaunchAgents/\(serviceLabel).plist"),
            logFile: home.appendingPathComponent("Library/Logs/weto.log")
        )
    }

    /// `root` — корень файловой системы; тесты подставляют временный каталог.
    static func system(root: URL = URL(fileURLWithPath: "/", isDirectory: true)) -> CLIPaths {
        CLIPaths(
            isSystem: true,
            dataDirectory: root.appendingPathComponent(
                "Library/Application Support/\(systemDirectoryName)", isDirectory: true
            ),
            servicePlist: root.appendingPathComponent("Library/LaunchDaemons/\(serviceLabel).plist"),
            logFile: root.appendingPathComponent("Library/Logs/weto.log")
        )
    }

    static var currentUser: CLIPaths {
        user(home: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
    }

    var statusFile: URL { dataDirectory.appendingPathComponent("status.json") }
    var lockFile: URL { dataDirectory.appendingPathComponent("run.lock") }
    var tokenFile: URL { dataDirectory.appendingPathComponent(Self.tokenAccount) }

    /// Есть ли на машине охрана от root: файл LaunchDaemon или системный каталог
    /// данных. Сам системный набор настроек лежит в `/var/root`, и обычному
    /// пользователю его не увидеть, поэтому каталог данных заводит любая команда
    /// root — он и служит признаком.
    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: servicePlist.path)
            || FileManager.default.fileExists(atPath: dataDirectory.path)
    }

    /// Каталог данных системной установки: `0755`, чтобы `status.json` читался
    /// без sudo. Всё остальное в нём root пишет с umask `077` — токен, журналы
    /// и учёт остаются `0600`.
    func prepareSystemDirectory() {
        guard isSystem else { return }
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        chmod(dataDirectory.path, 0o755)
    }
}
