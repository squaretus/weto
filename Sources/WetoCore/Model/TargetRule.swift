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

    public init(entry: String, displayName: String, kind: TargetKind, path: String) {
        self.entry = entry
        self.displayName = displayName
        self.kind = kind
        self.path = path
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
