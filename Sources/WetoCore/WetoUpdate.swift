import Foundation
import UpdateKitCore

/// Весь weto-специфичный клей механизма обновления: адреса, пути, имя сервиса.
/// Пакет `UpdateKit` не знает об этих значениях ничего — они приходят сюда.
public enum WetoUpdate {

    public static let configuration = UpdateFeedConfiguration(
        owner: "squaretus",
        repository: "weto",
        appDisplayName: "Weto",
        assetSuffix: ".pkg",
        machServiceName: "com.weto.helper",
        installedAppPath: "/Applications/Weto.app",
        clientExecutablePaths: ["/Applications/Weto.app/Contents/MacOS/WetoMenuBar"],
        debugClientExecutableSuffixes: [
            "/.build/debug/WetoMenuBar",
            "/.build/release/WetoMenuBar",
            "/.build/app/Weto.app/Contents/MacOS/WetoMenuBar",
        ],
        workingDirectory: "/var/db/weto/updates",
        daemonPlistPath: "/Library/LaunchDaemons/com.weto.helper.plist",
        daemonBinaryPath: "/Library/PrivilegedHelperTools/com.weto.helper",
        logSubsystem: "com.weto.helper",
        defaultsSuite: Constants.userDefaultsSuite
    )
}
