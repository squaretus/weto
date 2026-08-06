import Foundation
import WetoCore
import WetoXPC
import UpdateKitCore

/// Обслуживание XPC-соединений и установка обновлений под root.
final class HelperDelegate: NSObject, NSXPCListenerDelegate, WetoHelperProtocol {

    private let lock = NSLock()
    private var isInstalling = false
    private var lastFailure: String?

    /// Версия приложения, установленного в /Applications: демон сравнивает
    /// релиз именно с ней, а не со своей собственной сборкой. `nil` — прочитать
    /// не удалось; подставлять «0.0.0» нельзя, иначе любой релиз оказывается
    /// новее и демон под root ставит пакет на пустом основании.
    private var installedAppVersion: String? {
        let plist = "/Applications/Weto.app/Contents/Info.plist"
        guard let data = FileManager.default.contents(atPath: plist),
              let dictionary = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any],
              let version = dictionary["CFBundleShortVersionString"] as? String,
              !version.isEmpty
        else { return nil }
        return version
    }

    // MARK: - NSXPCListenerDelegate

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        let pid = connection.processIdentifier
        guard ClientAuthorization.isAuthorized(pid: pid) else {
            let path = ClientAuthorization.executablePath(forPID: pid) ?? "<неизвестно>"
            HelperLogger.error("соединение отклонено: pid=\(pid) path=\(path)")
            return false
        }

        connection.exportedInterface = NSXPCInterface(with: WetoHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        HelperLogger.log("соединение принято: pid=\(pid)")
        return true
    }

    // MARK: - WetoHelperProtocol

    func lastInstallFailure(reply: @escaping (String?) -> Void) {
        lock.lock()
        let failure = lastFailure
        lock.unlock()
        reply(failure)
    }

    func performUpdate(reply: @escaping (String?) -> Void) {
        lock.lock()
        if isInstalling {
            lock.unlock()
            reply("Установка уже идёт")
            return
        }
        isInstalling = true
        lastFailure = nil
        lock.unlock()

        guard let currentVersion = installedAppVersion else {
            finishInstalling()
            let message = "Не удалось прочитать версию установленного приложения"
            HelperLogger.error(message)
            reply(message)
            return
        }

        // Установка идёт только по данным собственной проверки демона:
        // клиент не передаёт ни ссылку, ни версию.
        UpdateChecker.checkLatestRelease(currentVersion: currentVersion) { [weak self] result in
            guard let self else { return }

            switch result {
            case .failure(let error):
                self.finishInstalling()
                HelperLogger.error("проверка перед установкой не удалась: \(error.localizedDescription)")
                reply(error.localizedDescription)

            case .success(let info):
                guard info.isNewer else {
                    self.finishInstalling()
                    reply("Обновления нет: установлена \(info.currentVersion)")
                    return
                }
                guard !info.downloadURL.isEmpty else {
                    self.finishInstalling()
                    reply(UpdateChecker.UpdateError.noPackage.localizedDescription)
                    return
                }

                // Клиенту отвечаем сразу: скачивание и установка идут дальше сами,
                // а установщик по ходу выгрузит и этот демон.
                reply(nil)
                self.downloadAndInstall(info)
            }
        }
    }

    func uninstallHelper(reply: @escaping (String?) -> Void) {
        let plist = "/Library/LaunchDaemons/com.weto.helper.plist"
        let binary = "/Library/PrivilegedHelperTools/com.weto.helper"
        var failures: [String] = []

        for path in [plist, binary, UpdateChecker.updatesDirectory] {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                failures.append("\(path): \(error.localizedDescription)")
            }
        }

        HelperLogger.log(failures.isEmpty ? "самоудаление: файлы убраны" : "самоудаление с ошибками")
        reply(failures.isEmpty ? nil : failures.joined(separator: "; "))

        // Выгружаемся последними и уже после ответа: bootout убивает процесс.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["bootout", "system/com.weto.helper"]
            try? process.run()
        }
    }

    // MARK: - Внутреннее

    private func downloadAndInstall(_ info: UpdateInfo) {
        HelperLogger.log("скачиваю \(info.latestVersion) с \(info.downloadURL)")

        // Провал записывается, а не только логируется: клиент спросит о нём
        // сам — ответ «установка начата» ушёл ещё до скачивания.
        UpdateChecker.downloadPackage(from: info.downloadURL) { [weak self] result in
            switch result {
            case .success(let path):
                HelperLogger.log("пакет на месте, запускаю установку")
                do {
                    try UpdateChecker.installPackage(atPath: path)
                    HelperLogger.log("установка завершена")
                } catch {
                    HelperLogger.error("установка не удалась: \(error.localizedDescription)")
                    self?.record(failure: "Установка не удалась: \(error.localizedDescription)")
                }
            case .failure(let error):
                HelperLogger.error("скачивание не удалось: \(error.localizedDescription)")
                self?.record(failure: "Не удалось скачать пакет: \(error.localizedDescription)")
            }
            self?.finishInstalling()
        }
    }

    private func record(failure: String) {
        lock.lock(); lastFailure = failure; lock.unlock()
    }

    private func finishInstalling() {
        lock.lock(); isInstalling = false; lock.unlock()
    }
}
