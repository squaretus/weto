import Foundation
import Darwin

/// Где искать цель, названную одним именем.
///
/// За протоколом — потому что настоящий источник запускает логин-шелл, и тестам
/// такое подсовывать нельзя.
public protocol SearchPathProviding: Sendable {
    /// Список каталогов. Дёшево: отвечает из кэша.
    func searchPaths() -> [String]

    /// То же, но с попыткой перечитать, если кэш успел устареть. Спрашивается
    /// только тогда, когда цель по имени не нашлась: инструмент могли поставить
    /// минуту назад, и перезапускать приложение ради этого незачем.
    func refreshedSearchPaths() -> [String]
}

/// `PATH` из логин-шелла пользователя.
///
/// Спрашивать приходится именно шелл: приложение поднимает launchd, и в окружении
/// процесса лежит его минимальный `PATH` — `/usr/bin:/bin:/usr/sbin:/sbin`.
/// Ни `~/.local/bin`, куда ставятся claude и codex, ни шимы asdf, mise и nvm
/// туда не попадают, поэтому цель, названная одним именем, не находилась.
/// Так же поступают все GUI-инструменты на macOS, которым нужен пользовательский
/// `PATH`.
///
/// Шелл берётся из записи пользователя, а не из `$SHELL`: в окружении от launchd
/// его нет вовсе.
///
/// Запуск один на процесс, с таймаутом: шелл с тяжёлым конфигом умеет стартовать
/// долго, а охране нельзя вставать на этом месте. Не ответил — остаётся встроенный
/// список, и цель, разрешённая раньше, не теряется: `ProcessEnforcer` держит
/// последнее известное правило.
public final class LoginShellSearchPaths: SearchPathProviding, @unchecked Sendable {

    /// Пол между перечитываниями. Разрешение цели идёт раз в две секунды на каждую
    /// цель, и без пола ненайденное имя запускало бы шелл непрерывно.
    public static let refreshFloorSeconds: TimeInterval = 60

    public static let timeoutSeconds: TimeInterval = 2

    /// Каталоги, которые есть всегда, даже когда шелл промолчал.
    ///
    /// Каталоги пользователя идут первыми: одноимённый файл в `/usr/bin`
    /// не должен перебивать тот, которым человек пользуется.
    public static var fallbackPaths: [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/.local/bin",
            "\(home)/bin",
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "/usr/local/sbin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
    }

    private let lock = NSLock()
    private var cached: [String]?
    private var readAt: Date?

    private let readShellPath: @Sendable () -> [String]
    private let now: @Sendable () -> Date

    public init(
        readShellPath: (@Sendable () -> [String])? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.readShellPath = readShellPath ?? LoginShellSearchPaths.askLoginShell
        self.now = now
    }

    public func searchPaths() -> [String] {
        lock.lock()
        if let cached {
            lock.unlock()
            return cached
        }
        lock.unlock()
        return read()
    }

    public func refreshedSearchPaths() -> [String] {
        lock.lock()
        let isFresh = readAt.map { now().timeIntervalSince($0) < Self.refreshFloorSeconds } ?? false
        if isFresh, let cached {
            lock.unlock()
            return cached
        }
        lock.unlock()
        return read()
    }

    @discardableResult
    private func read() -> [String] {
        // Шелл спрашивается вне замка: он может думать секунду, и держать на это
        // время всех остальных незачем.
        let fromShell = readShellPath()
        let paths = Self.merged(shell: fromShell, fallback: Self.fallbackPaths)

        lock.lock()
        cached = paths
        readAt = now()
        lock.unlock()
        return paths
    }

    /// Порядок пользователя сохраняется, встроенный список идёт следом страховкой.
    static func merged(shell: [String], fallback: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in shell + fallback where !path.isEmpty {
            if seen.insert(path).inserted { result.append(path) }
        }
        return result
    }

    /// `PATH` у логин-шелла: `-l` читает профиль, где `PATH` и собирается.
    private static let askLoginShell: @Sendable () -> [String] = {
        guard let shell = userShell() else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "printf %s \"$PATH\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        // Стандартный ввод закрыт: шелл с интерактивным конфигом иначе умеет
        // ждать ввода и не завершиться никогда.
        process.standardInput = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return [] }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        guard !process.isRunning else {
            process.terminate()
            return []
        }

        guard let data = try? output.fileHandleForReading.readToEnd(),
              let text = String(data: data, encoding: .utf8)
        else { return [] }

        return text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":")
            .map(String.init)
    }

    /// Логин-шелл берётся из записи пользователя: в окружении от launchd
    /// переменной `SHELL` нет.
    private static func userShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else {
            return nil
        }
        let path = String(cString: shell)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}

/// Готовый список — для тестов и для случая, когда шелл спрашивать не нужно.
public struct StaticSearchPaths: SearchPathProviding {
    private let paths: [String]

    public init(_ paths: [String]) { self.paths = paths }

    public func searchPaths() -> [String] { paths }
    public func refreshedSearchPaths() -> [String] { paths }
}
