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

public struct MatchedProcess: Equatable, Sendable {
    public let pid: Int32

    public let targetName: String

    public init(pid: Int32, targetName: String) {
        self.pid = pid
        self.targetName = targetName
    }
}
