import Foundation

/// Чем оказалась цель после разрешения.
///
/// Различие не косметическое: у каждого вида свой способ найти процесс.
/// Приложение ищется по префиксу пути бандла, бинарник — точным совпадением
/// пути, скрипт — по командной строке, потому что система показывает его
/// под именем интерпретатора.
public enum TargetKind: String, Equatable, Codable, Sendable {
    case appBundle
    case binary
    case script
}

/// Разрешённая цель: то, что ввёл пользователь, приведённое к виду,
/// пригодному для сравнения с процессами.
public struct TargetRule: Equatable, Sendable {
    /// Как записано в настройках: bundle ID, имя команды или путь.
    public let entry: String
    /// Человекочитаемое имя для журнала и настроек.
    public let displayName: String
    public let kind: TargetKind
    /// Разрешённый путь: бандл, бинарник после раскрытия симлинков либо скрипт.
    public let path: String

    public init(entry: String, displayName: String, kind: TargetKind, path: String) {
        self.entry = entry
        self.displayName = displayName
        self.kind = kind
        self.path = path
    }
}

/// Процесс, опознанный как принадлежащий цели.
public struct MatchedProcess: Equatable, Sendable {
    public let pid: Int32
    /// Имя цели, из-за которой процесс попал под нож. У потомков — имя цели предка.
    public let targetName: String

    public init(pid: Int32, targetName: String) {
        self.pid = pid
        self.targetName = targetName
    }
}
