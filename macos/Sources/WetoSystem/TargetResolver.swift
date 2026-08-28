import Foundation
import AppKit
import WetoCore

public protocol TargetResolving: Sendable {
    func resolve(_ entry: String) -> TargetRule?
}

public struct TargetResolver: TargetResolving {

    /// Откуда берётся список каталогов для поиска по имени.
    ///
    /// Настоящий источник — `PATH` логин-шелла: приложение поднимает launchd,
    /// и в окружении процесса лежит его минимальный `PATH`. Ни `~/.local/bin`,
    /// куда ставятся claude и codex, ни шимы asdf, mise и nvm туда не попадают.
    private let paths: SearchPathProviding

    public init(paths: SearchPathProviding = LoginShellSearchPaths()) {
        self.paths = paths
    }

    public func resolve(_ entry: String) -> TargetRule? {
        let trimmed = entry.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if let rule = resolveApplication(trimmed) { return rule }
        return resolveExecutable(trimmed)
    }

    private func resolveApplication(_ entry: String) -> TargetRule? {

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

    private func resolveExecutable(_ entry: String) -> TargetRule? {
        guard !entry.contains("/") else {
            return rule(forEntry: entry, at: (entry as NSString).expandingTildeInPath)
        }

        if let rule = search(entry, in: paths.searchPaths()) { return rule }

        // Имя не нашлось. Инструмент могли поставить минуту назад — и тогда
        // каталог появился в `PATH` уже после того, как мы его прочитали.
        // Перечитывание не бесплатное, поэтому у него свой пол по времени.
        return search(entry, in: paths.refreshedSearchPaths())
    }

    private func search(_ entry: String, in directories: [String]) -> TargetRule? {
        for directory in directories {
            if let rule = rule(forEntry: entry, at: "\(directory)/\(entry)") { return rule }
        }
        return nil
    }

    private func rule(forEntry entry: String, at candidate: String) -> TargetRule? {
        guard FileManager.default.isExecutableFile(atPath: candidate) else { return nil }

        let real = (candidate as NSString).resolvingSymlinksInPath
        return TargetRule(
            entry: entry,
            displayName: entry.contains("/") ? (entry as NSString).lastPathComponent : entry,
            kind: Self.hasShebang(atPath: real) ? .script : .binary,
            path: real,
            launchPaths: [candidate]
        )
    }

    private static func hasShebang(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 2) else { return false }
        return head == Data([0x23, 0x21])
    }
}
