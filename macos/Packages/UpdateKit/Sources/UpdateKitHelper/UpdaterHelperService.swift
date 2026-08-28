import Foundation
import UpdateKitCore
import UpdateKitXPC

/// Обслуживание XPC-соединений и установка обновлений под root.
/// Единственный публичный тип демона: приложение проекта собирает его
/// из своей конфигурации и отдаёт `NSXPCListener`.
public final class UpdaterHelperService: NSObject, NSXPCListenerDelegate, UpdaterHelperProtocol {

    private let configuration: UpdateFeedConfiguration
    private let authorization: ClientAuthorization
    private let logger: HelperLogger
    private let state = HelperInstallState()
    private let flow: HelperUpdateFlow

    public init(configuration: UpdateFeedConfiguration) {
        self.configuration = configuration
        self.authorization = ClientAuthorization(configuration: configuration)

        let logger = HelperLogger(subsystem: configuration.logSubsystem)
        self.logger = logger

        let state = self.state
        let checker = ReleaseChecker(configuration: configuration)
        let downloader = PackageDownloader(configuration: configuration)
        let installer = PackageInstaller()

        self.flow = HelperUpdateFlow(
            configuration: configuration,
            state: state,
            checkRelease: { version, completion in
                checker.checkLatestRelease(currentVersion: version, completion: completion)
            },
            download: { url, onProgress, completion in
                logger.log("скачиваю \(url)")
                downloader.download(from: url, onProgress: onProgress, completion: completion)
            },
            install: { path in
                logger.log("пакет на месте, запускаю установку")
                try installer.install(atPath: path)
                logger.log("установка завершена")
            }
        )
        super.init()
    }

    public func logStart() {
        logger.log("слушаю \(configuration.machServiceName)")
    }

    /// Версия приложения, установленного в системе: демон сравнивает релиз именно
    /// с ней, а не со своей собственной сборкой. `nil` — прочитать не удалось;
    /// подставлять «0.0.0» нельзя, иначе любой релиз оказывается новее и демон
    /// под root ставит пакет на пустом основании.
    private var installedAppVersion: String? {
        guard let data = FileManager.default.contents(atPath: configuration.installedAppInfoPlistPath),
              let dictionary = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any],
              let version = dictionary["CFBundleShortVersionString"] as? String,
              !version.isEmpty
        else { return nil }
        return version
    }

    // MARK: - NSXPCListenerDelegate

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        let pid = connection.processIdentifier
        guard authorization.isAuthorized(pid: pid) else {
            let path = ClientAuthorization.executablePath(forPID: pid) ?? "<неизвестно>"
            logger.error("соединение отклонено: pid=\(pid) path=\(path)")
            return false
        }

        connection.exportedInterface = NSXPCInterface(with: UpdaterHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        logger.log("соединение принято: pid=\(pid)")
        return true
    }

    // MARK: - UpdaterHelperProtocol

    public func performUpdate(reply: @escaping (String?) -> Void) {
        let logger = self.logger
        let sendableReply = UncheckedSendableReply(reply)

        flow.start(currentVersion: installedAppVersion) { failure in
            if let failure {
                logger.error("установка не начата: \(failure)")
            }
            sendableReply.call(failure)
        }
    }

    public func installState(reply: @escaping (Int, Double, String?) -> Void) {
        let triple = state.current.xpc
        reply(triple.phase, triple.fraction, triple.failure)
    }

    /// Самоудаление демона — и приложения, которое он обслуживает.
    ///
    /// Бандл сносится здесь, а не приложением: его ставит установщик под root,
    /// и `/Applications/<app>` принадлежит root:wheel. Приложение пыталось
    /// удалить его само, `rm -rf` упирался в права, а об отказе никто не узнавал —
    /// приложение оставалось на диске после «удалить полностью».
    ///
    /// Удалять бандл работающего приложения безопасно: образы уже отображены
    /// в память, и процесс доживает до своего выхода.
    public func uninstallHelper(reply: @escaping (String?) -> Void) {
        var failures: [String] = []

        let paths = [
            configuration.installedAppPath,
            configuration.daemonPlistPath,
            configuration.daemonBinaryPath,
            configuration.workingDirectory,
        ] + configuration.additionalUninstallPaths

        for path in paths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                failures.append("\(path): \(error.localizedDescription)")
            }
        }

        // Чек установки: без этого система считает пакет установленным, хотя
        // ни одного его файла на диске уже нет.
        if let identifier = configuration.packageIdentifier {
            let forget = Process()
            forget.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
            forget.arguments = ["--forget", identifier]
            forget.standardOutput = Pipe()
            forget.standardError = Pipe()
            try? forget.run()
            forget.waitUntilExit()
        }

        logger.log(failures.isEmpty ? "самоудаление: файлы убраны" : "самоудаление с ошибками")
        reply(failures.isEmpty ? nil : failures.joined(separator: "; "))

        // Выгружаемся последними и уже после ответа: bootout убивает процесс.
        let service = configuration.machServiceName
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["bootout", "system/\(service)"]
            try? process.run()
        }
    }
}

/// Ответ XPC приходит обычным (не `@Sendable`) замыканием, а границы демона
/// зовут его с чужой очереди. Обёртка делает это намерение явным.
private final class UncheckedSendableReply: @unchecked Sendable {
    private let reply: (String?) -> Void

    init(_ reply: @escaping (String?) -> Void) {
        self.reply = reply
    }

    func call(_ value: String?) { reply(value) }
}
