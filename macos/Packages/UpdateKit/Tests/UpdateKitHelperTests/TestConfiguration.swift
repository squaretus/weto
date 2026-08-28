import Foundation
import UpdateKitCore

extension UpdateFeedConfiguration {

    /// Конфигурация для тестов пакета: значения не относятся ни к одному
    /// настоящему проекту, чтобы тест не проверял чужие константы.
    static let testing = UpdateFeedConfiguration(
        owner: "example",
        repository: "sample",
        appDisplayName: "Sample",
        assetSuffix: ".pkg",
        machServiceName: "com.example.helper",
        installedAppPath: "/Applications/Sample.app",
        clientExecutablePaths: ["/Applications/Sample.app/Contents/MacOS/Sample"],
        debugClientExecutableSuffixes: [],
        workingDirectory: "/var/db/sample/updates",
        daemonPlistPath: "/Library/LaunchDaemons/com.example.helper.plist",
        daemonBinaryPath: "/Library/PrivilegedHelperTools/com.example.helper",
        logSubsystem: "com.example.helper",
        defaultsSuite: "com.example.shared"
    )
}

extension UpdateFeedConfiguration {

    /// Тот же набор, но с путями во временном каталоге: самоудаление проверяется
    /// на настоящих файлах, а не на системных.
    static func testing(
        installedAppPath: String,
        workingDirectory: String,
        daemonPlistPath: String,
        daemonBinaryPath: String,
        additionalUninstallPaths: [String] = []
    ) -> UpdateFeedConfiguration {
        UpdateFeedConfiguration(
            owner: "example",
            repository: "sample",
            appDisplayName: "Sample",
            assetSuffix: ".pkg",
            machServiceName: "com.example.helper",
            installedAppPath: installedAppPath,
            clientExecutablePaths: ["\(installedAppPath)/Contents/MacOS/Sample"],
            debugClientExecutableSuffixes: [],
            workingDirectory: workingDirectory,
            daemonPlistPath: daemonPlistPath,
            daemonBinaryPath: daemonBinaryPath,
            logSubsystem: "com.example.helper",
            defaultsSuite: "com.example.shared",
            additionalUninstallPaths: additionalUninstallPaths
        )
    }
}
