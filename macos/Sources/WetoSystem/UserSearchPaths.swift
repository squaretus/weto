import Darwin
import Foundation

/// `PATH` пользователя по имени — для `sudo weto target add claude`.
///
/// Под root голое имя ищется по `PATH` root, а `claude` стоит в `~/.local/bin`
/// того, кто вызвал sudo: цель не находилась, и охрана всей машины её не видела.
/// Поэтому спрашивается логин-шелл этого пользователя — тем же способом, каким
/// приложение спрашивает свой (`LoginShellSearchPaths`), но от его имени.
/// Граница системы: в тестах подменяется.
public protocol UserSearchPathProviding: Sendable {
    /// `PATH` логин-шелла пользователя; `nil` — шелл не ответил или спросить нельзя.
    func loginShellPath(ofUser user: String) -> [String]?
    /// Домашний каталог из базы учётных записей.
    func homeDirectory(ofUser user: String) -> String?
}

public struct AccountSearchPaths: UserSearchPathProviding {

    /// Чужой логин-шелл с тяжёлым профилем думает дольше своего — у команды
    /// человек ждёт в терминале, а не охрана на такте.
    public static let timeoutSeconds: TimeInterval = 3

    /// Метка перед значением: профиль пользователя волен печатать что угодно
    /// (приветствие, `fortune`), и брать весь вывод за `PATH` нельзя.
    static let marker = "WETO_PATH="

    public init() {}

    public func homeDirectory(ofUser user: String) -> String? {
        guard let entry = getpwnam(user), let directory = entry.pointee.pw_dir else { return nil }
        return String(cString: directory)
    }

    public func loginShellPath(ofUser user: String) -> [String]? {
        guard let entry = getpwnam(user) else { return nil }
        let script = "printf '\\n\(Self.marker)%s' \"$PATH\""

        let process = Process()
        if geteuid() == 0 {
            // root входит за пользователя без пароля; `su -l` берёт шелл из базы
            // учётных записей и читает его профиль, где `PATH` и собирается.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/su")
            process.arguments = ["-l", user, "-c", script]
        } else if entry.pointee.pw_uid == getuid(), let shell = entry.pointee.pw_shell {
            // Свой собственный — тем же логин-шеллом, без su.
            process.executableURL = URL(fileURLWithPath: String(cString: shell))
            process.arguments = ["-lc", script]
        } else {
            return nil
        }
        return Self.run(process).flatMap(Self.parse)
    }

    /// `PATH` из вывода — после метки; пустые элементы выбрасываются.
    public static func parse(_ output: String) -> [String]? {
        guard let range = output.range(of: marker, options: .backwards) else { return nil }
        let value = output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = value.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        return paths.isEmpty ? nil : paths
    }

    private static func run(_ process: Process) -> String? {
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // Ввод закрыт: интерактивный профиль иначе ждал бы его вечно.
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        // Вывод читается сразу, а не после выхода: болтливый профиль иначе
        // упёрся бы в заполненную трубу и не вышел бы никогда.
        let reader = OutputCollector(handle: output.fileHandleForReading)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        guard !process.isRunning else {
            process.terminate()
            return nil
        }
        return reader.finish()
    }
}

/// Читает трубу в своей очереди до конца потока.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(handle: FileHandle) {
        DispatchQueue.global().async { [self] in
            let all = (try? handle.readToEnd()) ?? nil
            lock.lock(); data = all ?? Data(); lock.unlock()
            done.signal()
        }
    }

    func finish() -> String? {
        guard done.wait(timeout: .now() + 1) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8)
    }
}

/// Поиск исполняемого файла у пользователя: сначала его `PATH`, потом
/// общепринятые каталоги — на случай, когда шелл промолчал или там не нашлось.
public enum UserExecutableSearch {

    /// Куда ставят инструменты пользователи; `/opt/homebrew/bin` и `/usr/local/bin`
    /// root обычно уже видит, но шелл мог промолчать.
    public static func fallbackDirectories(home: String) -> [String] {
        [
            "\(home)/.local/bin", "\(home)/bin", "\(home)/.cargo/bin", "\(home)/.bun/bin",
            "\(home)/.deno/bin", "\(home)/.npm-global/bin",
            "/opt/homebrew/bin", "/usr/local/bin",
        ]
    }

    /// Первый исполняемый файл с этим именем. Путь — как он лежит в каталоге,
    /// без разворота симлинков: `~/.local/bin/claude` переживает обновление цели,
    /// а `…/versions/2.1.228` — нет. Разворачивает его охрана при каждом разрешении.
    public static func find(_ name: String, user: String, in provider: UserSearchPathProviding) -> String? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        var directories = provider.loginShellPath(ofUser: user) ?? []
        if let home = provider.homeDirectory(ofUser: user) {
            directories += fallbackDirectories(home: home)
        }
        var seen = Set<String>()
        for directory in directories where seen.insert(directory).inserted {
            let candidate = (directory as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
