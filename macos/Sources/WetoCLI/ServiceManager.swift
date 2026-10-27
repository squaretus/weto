import Foundation

/// Сервис терминальной версии — задание launchd `com.weto.cli`.
///
/// Обычный пользователь ставит LaunchAgent в свой домен `gui/<uid>`, root —
/// LaunchDaemon в домен `system`: охрана всей машины, без входа пользователя.
///
/// Это не автозапуск приложения: тот живёт ровно одним файлом `com.weto.app.plist`,
/// и его правило сюда не относится. Здесь своё задание со своим именем — и `bootout`
/// его из `weto service` не стреляет в работающую охрану по ошибке: охрану
/// держит launchd, а команду запускает пользователь отдельным процессом.
struct ServiceManager {

    let paths: CLIPaths
    let control: ServiceControlling
    let uid: uid_t

    var domain: String { paths.isSystem ? "system" : "gui/\(uid)" }
    var target: String { "\(domain)/\(CLIPaths.serviceLabel)" }

    /// Текст plist — чистая функция, проверяемая тестом.
    ///
    /// `ProcessType Interactive`: фоновый тип launchd троттлит таймеры, и секундный
    /// опрос растягивался бы на минуты — та же беда, что App Nap у приложения.
    /// `KeepAlive {SuccessfulExit: false}`: штатный выход по SIGTERM (`bootout`)
    /// сервис не поднимает, падение — поднимает.
    static func plistText(executable: String, logPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Label</key>
        \t<string>\(escaped(CLIPaths.serviceLabel))</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>\(escaped(executable))</string>
        \t\t<string>run</string>
        \t</array>
        \t<key>RunAtLoad</key>
        \t<true/>
        \t<key>KeepAlive</key>
        \t<dict>
        \t\t<key>SuccessfulExit</key>
        \t\t<false/>
        \t</dict>
        \t<key>ProcessType</key>
        \t<string>Interactive</string>
        \t<key>StandardOutPath</key>
        \t<string>\(escaped(logPath))</string>
        \t<key>StandardErrorPath</key>
        \t<string>\(escaped(logPath))</string>
        </dict>
        </plist>

        """
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Бинарник внутри каталога сборки исчезнет или сменится при пересборке —
    /// сервис будет поднимать то, чего уже нет.
    static func isInsideBuildDirectory(_ path: String) -> Bool {
        path.contains("/.build/") || path.contains("/target/")
    }

    enum InstallOutcome: Equatable {
        /// Задания не было — оно загружено впервые.
        case installed(warnings: [String])
        /// Задание уже было загружено — перезапущено на новом бинарнике.
        case reinstalled(warnings: [String])
        case failed(String)
    }

    /// Установка идемпотентна: установочный скрипт зовёт её и при первой установке,
    /// и поверх прежней, после замены бинарника. Загруженное задание перезапускается,
    /// чтобы подхватить новый бинарник: plist тот же — `kickstart -k`, другой —
    /// `bootout` и `bootstrap` (launchd перечитывает plist только при загрузке).
    func install(executable: String) -> InstallOutcome {
        var warnings: [String] = []
        if Self.isInsideBuildDirectory(executable) {
            warnings.append("бинарник лежит в каталоге сборки (\(executable)) — сервис сломается при пересборке; "
                + "положите weto на постоянное место и установите сервис оттуда")
        }

        let plist = paths.servicePlist
        let text = Self.plistText(executable: executable, logPath: paths.logFile.path)
        let previous = try? String(contentsOf: plist, encoding: .utf8)
        let wasLoaded = control.launchctl(["print", target]).status == 0

        if previous != text {
            do {
                try FileManager.default.createDirectory(
                    at: plist.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try FileManager.default.createDirectory(
                    at: paths.logFile.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try text.write(to: plist, atomically: true, encoding: .utf8)
                // launchd не грузит LaunchDaemon, доступный на запись не владельцу;
                // umask root-процесса (`077`) дал бы `0600` — права задаются явно.
                chmod(plist.path, 0o644)
            } catch {
                return .failed("не удалось записать \(plist.path): \(error.localizedDescription)")
            }
        }

        if wasLoaded, previous == text {
            let result = control.launchctl(["kickstart", "-k", target])
            guard result.status == 0 else { return .failed(Self.refusal("перезапускать", result)) }
            return .reinstalled(warnings: warnings)
        }
        if wasLoaded {
            // bootstrap поверх загруженного задания launchd отвергает.
            _ = control.launchctl(["bootout", target])
        }
        let result = control.launchctl(["bootstrap", domain, plist.path])
        guard result.status == 0 else { return .failed(Self.refusal("загружать", result)) }
        return wasLoaded ? .reinstalled(warnings: warnings) : .installed(warnings: warnings)
    }

    private static func refusal(_ verb: String, _ result: (status: Int32, output: String)) -> String {
        "launchd отказался \(verb) задание (код \(result.status)): "
            + result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum RestartOutcome: Equatable {
        /// Задание не загружено или не запущено — перезапускать нечего.
        case notRunning
        case restarted
        case failed(String)
    }

    /// После замены бинарника: работающая охрана выходит штатно (стоящим — SIGCONT),
    /// launchd поднимает новый бинарник, и тот подхватывает учёт остановленных.
    func restartIfRunning() -> RestartOutcome {
        guard state().runningPID != nil else { return .notRunning }
        let result = control.launchctl(["kickstart", "-k", target])
        guard result.status == 0 else { return .failed(Self.refusal("перезапускать", result)) }
        return .restarted
    }

    /// Остановить, выгрузить, удалить файл. Учёт остановленных остаётся:
    /// его разберёт следующий `run`.
    func uninstall() -> Result<Void, UsageError> {
        _ = control.launchctl(["bootout", target])
        let plist = paths.servicePlist
        guard FileManager.default.fileExists(atPath: plist.path) else { return .success(()) }
        do {
            try FileManager.default.removeItem(at: plist)
            return .success(())
        } catch {
            return .failure(UsageError(message: "не удалось удалить \(plist.path): \(error.localizedDescription)"))
        }
    }

    struct State: Equatable {
        let isInstalled: Bool
        let isLoaded: Bool
        /// `state = running` и `pid = N` из `launchctl print`.
        let runningPID: Int32?
        let launchdState: String?
    }

    func state() -> State {
        let installed = FileManager.default.fileExists(atPath: paths.servicePlist.path)
        let printed = control.launchctl(["print", target])
        guard printed.status == 0 else {
            return State(isInstalled: installed, isLoaded: false, runningPID: nil, launchdState: nil)
        }
        let parsed = Self.parsePrint(printed.output)
        return State(isInstalled: installed, isLoaded: true, runningPID: parsed.pid, launchdState: parsed.state)
    }

    /// Из вывода `launchctl print` нужны две строки верхнего уровня задания.
    static func parsePrint(_ output: String) -> (state: String?, pid: Int32?) {
        var state: String?
        var pid: Int32?
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if state == nil, line.hasPrefix("state = ") {
                state = String(line.dropFirst("state = ".count))
            } else if pid == nil, line.hasPrefix("pid = ") {
                pid = Int32(line.dropFirst("pid = ".count))
            }
        }
        return (state, pid)
    }
}
