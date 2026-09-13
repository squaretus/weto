import Foundation

public enum TargetKind: String, Equatable, Codable, Sendable {
    case appBundle
    case binary
    case script
}

public struct TargetRule: Equatable, Sendable {

    public let entry: String

    public let displayName: String
    public let kind: TargetKind

    public let path: String

    /// Пути, по которым цель может встретиться в аргументах процесса: сам путь запуска
    /// (обычно симлинк в PATH) и всё, во что он разворачивается.
    public let launchPaths: [String]

    public init(
        entry: String,
        displayName: String,
        kind: TargetKind,
        path: String,
        launchPaths: [String] = []
    ) {
        self.entry = entry
        self.displayName = displayName
        self.kind = kind
        self.path = path

        var paths = [path]
        for candidate in launchPaths where !paths.contains(candidate) {
            paths.append(candidate)
        }
        self.launchPaths = paths
    }
}

public struct RunningTarget: Equatable, Sendable, Identifiable {

    public let entry: String
    public let displayName: String
    public let kind: TargetKind
    public let path: String

    public let pid: Int32
    public let processCount: Int

    public var id: Int32 { pid }

    public var extraProcessCount: Int { max(0, processCount - 1) }

    public init(
        entry: String,
        displayName: String,
        kind: TargetKind,
        path: String,
        pid: Int32,
        processCount: Int
    ) {
        self.entry = entry
        self.displayName = displayName
        self.kind = kind
        self.path = path
        self.pid = pid
        self.processCount = processCount
    }
}

/// Чем процесс попал под охрану: сам совпал с правилом или оказался потомком совпавшего.
/// Потомки объясняют, почему у одной цели десятки записей; «совпал сам» у процесса
/// внутри бандла — тоже норма (хелперы приложения совпадают по пути).
public enum MatchBasis: String, Codable, Equatable, Sendable {
    case rule
    case descendant

    /// Не цель вовсе: шелл, вошедший в план паузы ради терминала цели. Под правило
    /// он не подходил ни одной буквой, а SIGSTOP получил — и значит, обязан быть
    /// объяснён журналом наравне с целями.
    case shell

    /// Чем запись объясняет своё присутствие в журнале. У совпавшего по правилу
    /// объяснять нечего — он и есть цель.
    public func detailText(parentPID: Int32) -> String? {
        switch self {
        case .rule: return nil
        case .descendant: return "потомок \(parentPID)"
        case .shell: return "шелл терминала цели"
        }
    }
}

public struct MatchedProcess: Equatable, Sendable {
    public let pid: Int32

    public let targetName: String

    public let parentPID: Int32

    public let executablePath: String

    /// Процесс попал под охрану не сам по себе, а как потомок совпавшего.
    /// Именно потомки объясняют, почему у одной цели десятки завершений.
    public let matchedBy: MatchBasis

    public init(
        pid: Int32,
        targetName: String,
        parentPID: Int32 = 0,
        executablePath: String = "",
        matchedBy: MatchBasis = .rule
    ) {
        self.pid = pid
        self.targetName = targetName
        self.parentPID = parentPID
        self.executablePath = executablePath
        self.matchedBy = matchedBy
    }
}
