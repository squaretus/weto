import Foundation
import AppKit
import WetoCore

/// Граница системы: превращение записи из настроек в правило поиска процессов.
public protocol TargetResolving: Sendable {
    func resolve(_ entry: String) -> TargetRule?
}

/// Единый разрешатель целей: приложение, бинарник или скрипт.
///
/// Три ловушки, ради которых это существует:
///   * `/usr/bin/nano` — симлинк на `pico`, и ядро сообщает `pico`.
///     Без раскрытия симлинка цель молча не находилась бы;
///   * `qwen` — Node-скрипт, ядро показывает его как `node`. Матчинг по пути
///     выкосил бы все Node-процессы системы, поэтому скрипты ищутся по argv;
///   * приложение может быть задано и bundle ID, и путём к `.app`.
public struct TargetResolver: TargetResolving {

    /// Каталоги поиска для целей, заданных голым именем.
    /// Homebrew раньше системных: пользователь, набравший `nano` в терминале,
    /// получит ту же версию, что и мы.
    private static let searchPaths = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin",
        "/usr/local/bin", "/usr/local/sbin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    public init() {}

    public func resolve(_ entry: String) -> TargetRule? {
        let trimmed = entry.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if let rule = resolveApplication(trimmed) { return rule }
        return resolveExecutable(trimmed)
    }

    // MARK: - Приложения

    private func resolveApplication(_ entry: String) -> TargetRule? {
        // Путь к бандлу.
        if entry.hasSuffix(".app") || entry.hasSuffix(".app/") {
            var path = entry
            while path.hasSuffix("/") { path.removeLast() }
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return TargetRule(
                entry: entry,
                displayName: ((path as NSString).deletingPathExtension as NSString).lastPathComponent,
                kind: .appBundle,
                path: path
            )
        }

        // Bundle ID: без слэшей и с точкой — иначе это команда вроде `nano`.
        guard !entry.contains("/"), entry.contains("."),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry)
        else { return nil }

        return TargetRule(
            entry: entry,
            displayName: url.deletingPathExtension().lastPathComponent,
            kind: .appBundle,
            path: url.path
        )
    }

    // MARK: - Бинарники и скрипты

    private func resolveExecutable(_ entry: String) -> TargetRule? {
        let candidates = entry.contains("/")
            ? [(entry as NSString).expandingTildeInPath]
            : Self.searchPaths.map { "\($0)/\(entry)" }

        let fm = FileManager.default
        for candidate in candidates where fm.isExecutableFile(atPath: candidate) {
            let real = (candidate as NSString).resolvingSymlinksInPath
            let isScript = Self.hasShebang(atPath: real)
            return TargetRule(
                entry: entry,
                displayName: entry.contains("/") ? (entry as NSString).lastPathComponent : entry,
                kind: isScript ? .script : .binary,
                path: real
            )
        }
        return nil
    }

    /// Скрипты начинаются с `#!`; машинный код — с magic-числа Mach-O.
    private static func hasShebang(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 2) else { return false }
        return head == Data([0x23, 0x21])
    }
}
