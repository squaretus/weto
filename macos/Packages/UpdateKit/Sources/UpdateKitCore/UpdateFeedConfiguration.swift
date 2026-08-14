import Foundation

/// Всё, чем один проект отличается от другого в механизме обновления.
///
/// Пакет не знает ни одной константы конкретного приложения: адреса, пути,
/// имя mach-сервиса и интервалы приходят сюда снаружи. Перенос механизма
/// в новый проект — это новое значение этой структуры и адаптер темы,
/// а не правка кода пакета.
public struct UpdateFeedConfiguration: Equatable, Sendable {

    public let owner: String
    public let repository: String
    public let appDisplayName: String

    /// Расширение ассета релиза, который умеет ставить демон.
    public let assetSuffix: String

    public let machServiceName: String

    /// Путь установленного приложения: демон читает оттуда версию, с которой
    /// сравнивает релиз. Свою собственную сборку он сравнивать не должен.
    public let installedAppPath: String

    /// Кому позволено говорить с демоном — полные пути исполняемых файлов.
    public let clientExecutablePaths: [String]

    /// Пути отладочных сборок; проверяются только в DEBUG-сборке демона.
    public let debugClientExecutableSuffixes: [String]

    /// Каталог под скачанный пакет: создаётся под root с правами 0700.
    public let workingDirectory: String

    public let daemonPlistPath: String
    public let daemonBinaryPath: String
    public let logSubsystem: String

    /// Сюит `UserDefaults`, в котором живут пропуск версии, отсрочка и тумблер.
    public let defaultsSuite: String

    public let checkInterval: TimeInterval
    public let progressPollInterval: TimeInterval

    public init(
        owner: String,
        repository: String,
        appDisplayName: String,
        assetSuffix: String,
        machServiceName: String,
        installedAppPath: String,
        clientExecutablePaths: [String],
        debugClientExecutableSuffixes: [String],
        workingDirectory: String,
        daemonPlistPath: String,
        daemonBinaryPath: String,
        logSubsystem: String,
        defaultsSuite: String,
        checkInterval: TimeInterval = 3600,
        progressPollInterval: TimeInterval = 0.4
    ) {
        self.owner = owner
        self.repository = repository
        self.appDisplayName = appDisplayName
        self.assetSuffix = assetSuffix
        self.machServiceName = machServiceName
        self.installedAppPath = installedAppPath
        self.clientExecutablePaths = clientExecutablePaths
        self.debugClientExecutableSuffixes = debugClientExecutableSuffixes
        self.workingDirectory = workingDirectory
        self.daemonPlistPath = daemonPlistPath
        self.daemonBinaryPath = daemonBinaryPath
        self.logSubsystem = logSubsystem
        self.defaultsSuite = defaultsSuite
        self.checkInterval = checkInterval
        self.progressPollInterval = progressPollInterval
    }

    public var latestReleaseURL: String {
        "https://api.github.com/repos/\(owner)/\(repository)/releases/latest"
    }

    public var releasesPageURL: String {
        "https://github.com/\(owner)/\(repository)/releases/latest"
    }

    public var repositoryURL: String {
        "https://github.com/\(owner)/\(repository)"
    }

    public var packagePath: String {
        "\(workingDirectory)/update.pkg"
    }

    /// Версия установленного приложения читается из его `Info.plist`.
    public var installedAppInfoPlistPath: String {
        "\(installedAppPath)/Contents/Info.plist"
    }
}
