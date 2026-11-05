import Foundation
import AppKit
import Darwin
import WetoCore

public enum TerminalReturnError: Error, Equatable, Sendable {
    /// Ни tmux, ни управляемого терминала: ввести `fg` за пользователя нечем.
    case noWayToType
    /// tmux есть, а панели с терминалом цели на его сокетах нет.
    case paneNotFound
    /// Команда запустилась и не сработала: код выхода, в том числе отказ в Automation.
    case commandFailed(Int32)
    case timedOut
}

/// Вернуть цель на передний план её терминала, введя `fg` в её шелл.
///
/// Снаружи сессии терминал не отдать: `tcsetpgrp` требует быть в этой сессии, а `TIOCSTI`
/// не от root запрещён (проверено на macOS). Остаётся ввод через того, кто терминал ведёт.
/// Вызывать только когда шелл стоит на приглашении (`PausePlanner.shellHoldingTerminal`):
/// иначе введённое досталось бы чужой программе.
public protocol TerminalForegroundReturning: Sendable {
    func returnToForeground(
        target: ProcessSnapshot,
        shell: ProcessSnapshot,
        processes: [ProcessSnapshot],
        usingAutomation: Bool
    ) -> Result<Void, TerminalReturnError>
}

/// Два пути. tmux — главный: только под ним шелл и забирает терминал у стоящей цели.
/// Terminal.app и iTerm2 без tmux цель впереди держат и сами, а AppleScript нужен на случай,
/// когда она всё же ушла в фон; его первый запуск спросит разрешение Automation.
public struct TerminalForegroundReturner: TerminalForegroundReturning {

    private let allowsAutomation: Bool

    /// `allowsAutomation` выключает терминальная версия: у неё нет окна, чтобы спросить
    /// разрешение, а от root она управляла бы чужой сессией. Отдельно `usingAutomation`
    /// в вызове: на выходе из Weto ждать окно разрешения нельзя.
    public init(allowsAutomation: Bool = true) {
        self.allowsAutomation = allowsAutomation
    }

    public func returnToForeground(
        target: ProcessSnapshot,
        shell: ProcessSnapshot,
        processes: [ProcessSnapshot],
        usingAutomation: Bool
    ) -> Result<Void, TerminalReturnError> {
        guard Self.mayType(euid: geteuid()),
              let tty = TerminalModeKeeper.path(of: target.terminalDevice)
        else { return .failure(.noWayToType) }

        if let tmux = Self.tmuxServer(above: shell, in: processes) {
            guard Self.isTrustedExecutable(at: tmux.executablePath) else { return .failure(.noWayToType) }
            return typeThroughTmux(binary: tmux.executablePath, tty: tty)
        }

        guard allowsAutomation, usingAutomation,
              let host = TerminalLocator.hostApplicationPID(of: target.pid, in: processes),
              let bundleID = NSRunningApplication(processIdentifier: host)?.bundleIdentifier,
              let script = Self.automationScript(bundleID: bundleID, tty: tty)
        else { return .failure(.noWayToType) }

        // Запас на окно разрешения Automation при первом запуске.
        return Self.run("/usr/bin/osascript", ["-e", script], timeout: 30).map { _ in }
    }

    /// Сервер tmux над шеллом. Не обязательно родитель: шелл бывает вложенным,
    /// `tmux → zsh → bash → цель`.
    static func tmuxServer(above shell: ProcessSnapshot, in processes: [ProcessSnapshot]) -> ProcessSnapshot? {
        ProcessTree(processes: processes).ancestors(of: shell.pid).lazy
            .compactMap { pid in processes.first { $0.pid == pid } }
            .first { $0.executablePath.split(separator: "/").last == "tmux" }
    }

    /// Панель ищется перебором сокетов: окружение шелла (`TMUX`, `TMUX_PANE`) macOS чужому
    /// процессу не отдаёт. Мёртвые сокеты после упавших серверов отвечают ошибкой и пропускаются.
    private func typeThroughTmux(binary: String, tty: String) -> Result<Void, TerminalReturnError> {
        for socket in Self.tmuxSockets() {
            guard case .success(let listing) = Self.run(
                binary, ["-S", socket, "list-panes", "-a", "-F", "#{pane_tty} #{pane_id} #{pane_synchronized}"], timeout: 2
            ), let pane = Self.paneID(forTTY: tty, in: listing) else { continue }

            // Строка шелла редко пуста: цель включила отслеживание мыши и выключить его не может,
            // и отчёты идут в шелл без конца. C-u стирает их, и всё одной командой: в зазор между
            // двумя вклинились бы новые, склеились с `fg`, а Enter выполнил бы это как команды.
            return Self.run(binary, ["-S", socket, "send-keys", "-t", pane, "C-u", "fg", "Enter"], timeout: 2).map { _ in }
        }
        return .failure(.paneNotFound)
    }

    private static func tmuxSockets() -> [String] {
        let euid = geteuid()
        let directory = "/private/tmp/tmux-\(euid)"
        var info = stat()
        guard lstat(directory, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              isTrustedSocketDirectory(owner: info.st_uid, mode: info.st_mode, euid: euid)
        else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.sorted().map { "\(directory)/\($0)" }
    }

    /// Охрана от root стоит над всей машиной: процессы, которые она видит, принадлежат кому
    /// угодно, и запускать что-либо по их подсказке значит отдать root локальному пользователю.
    static func mayType(euid: uid_t) -> Bool {
        euid != 0
    }

    /// Путь к tmux взят из таблицы процессов, а назвать свой процесс `tmux` может кто угодно.
    /// Запускается только файл, который никто другой изменить не может.
    static func isTrustedExecutable(owner: uid_t, mode: mode_t, euid: uid_t) -> Bool {
        (owner == 0 || owner == euid) && mode & (S_IWGRP | S_IWOTH) == 0
    }

    private static func isTrustedExecutable(at path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
        return isTrustedExecutable(owner: info.st_uid, mode: info.st_mode, euid: geteuid())
    }

    /// `/tmp` общий: каталог `tmux-<uid>` мог заранее создать другой пользователь, и сокет
    /// в нём слушал бы он. Требование то же, что у самого tmux: наш и закрыт для остальных.
    static func isTrustedSocketDirectory(owner: uid_t, mode: mode_t, euid: uid_t) -> Bool {
        owner == euid && mode & (S_IRWXG | S_IRWXO) == 0
    }

    /// Панель с общим вводом (`synchronize-panes`) не подходит: `fg` ушёл бы во все панели окна.
    static func paneID(forTTY tty: String, in listing: String) -> String? {
        for line in listing.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count == 3, fields[0] == tty else { continue }
            return fields[2] == "1" ? nil : String(fields[1])
        }
        return nil
    }

    /// Control-U (`character id 21`) и `fg` одной записью: строку шелла надо стереть раньше, чем
    /// Enter её выполнит, а в зазор вклинились бы новые отчёты мыши.
    static func automationScript(bundleID: String, tty: String) -> String? {
        switch bundleID {
        case "com.apple.Terminal":
            return """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            do script ((character id 21) & "fg") in t
                            return
                        end if
                    end repeat
                end repeat
            end tell
            error "tab not found"
            """
        case "com.googlecode.iterm2":
            return """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                tell s to write text ((character id 21) & "fg" & linefeed) newline NO
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            error "session not found"
            """
        default:
            return nil
        }
    }

    /// Запуск с потолком времени: ни окно разрешения, ни зависший сервер tmux не должны
    /// держать поток дольше, чем нужно.
    private static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> Result<String, TerminalReturnError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return .failure(.commandFailed(-1))
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return .failure(.timedOut)
        }
        guard process.terminationStatus == 0 else { return .failure(.commandFailed(process.terminationStatus)) }
        return .success(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}
