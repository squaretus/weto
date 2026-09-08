import Foundation

/// Кому и в каком порядке слать SIGSTOP. Порядок — часть контракта (п. 7 спеки):
/// шелл раньше своей цели, родитель раньше потомков; продолжение — строго наоборот.
public struct PausePlan: Equatable, Sendable {

    public let stopOrder: [Int32]

    /// Шеллы, вошедшие в план ради терминала: они не цели и в журнал не пишутся.
    public let shells: [Int32]

    /// Корни целей, которым терминал после SIGCONT не вернуть: фоновое задание.
    /// Пользователю об этом говорит интерфейс (подсказка про `fg`).
    public let backgrounded: [Int32]

    /// Стояли до нас (Ctrl-Z): не трогаем ни при паузе, ни при возобновлении.
    public let skipped: [Int32]

    public var resumeOrder: [Int32] { stopOrder.reversed() }

    public init(stopOrder: [Int32], shells: [Int32], backgrounded: [Int32], skipped: [Int32]) {
        self.stopOrder = stopOrder
        self.shells = shells
        self.backgrounded = backgrounded
        self.skipped = skipped
    }
}

public enum PausePlanner {

    public static func plan(matched: [MatchedProcess], processes: [ProcessSnapshot]) -> PausePlan {
        var byPID: [Int32: ProcessSnapshot] = [:]
        for process in processes { byPID[process.pid] = process }
        let tree = ProcessTree(processes: processes)
        let matchedPIDs = Set(matched.map(\.pid))

        var skipped: [Int32] = []
        var active: [MatchedProcess] = []
        for process in matched {
            if byPID[process.pid]?.isStopped == true { skipped.append(process.pid) } else { active.append(process) }
        }

        // Шелл переднего задания: у корня цели есть tty и его группа — передняя группа tty.
        // Шелл — родитель лидера этой группы, и он в другой группе (иначе это обёртка, а не шелл).
        var shells: [Int32] = []
        var backgrounded: [Int32] = []
        for root in active where root.matchedBy == .rule {
            guard let snapshot = byPID[root.pid], snapshot.terminalForegroundGroup != 0 else { continue }
            guard snapshot.processGroup == snapshot.terminalForegroundGroup else {
                // Группа root'а не передняя группа терминала — обычно фоновое задание.
                // Но root может сам быть интерактивным шеллом, ждущим СВОЙ передний план:
                // тогда терминал занят его ребёнком (лидером terminalForegroundGroup),
                // а не root'ом, и это нормальное состояние шелла, а не «фон».
                if let foregroundLeader = byPID[snapshot.terminalForegroundGroup],
                   foregroundLeader.parentPID == root.pid {
                    continue
                }
                backgrounded.append(root.pid)
                continue
            }
            // Лидер группы обычно и есть сама цель. Если лидер уже вышел и в снимке его нет,
            // намеренно считаем root'а собственным лидером: родителя-шелла всё равно ищем
            // через parentPID, а не через факт лидерства, так что отсутствие лидера в снимке
            // на поиск шелла не влияет.
            let leader = byPID[snapshot.processGroup] ?? snapshot
            guard let shell = byPID[leader.parentPID],
                  shell.processGroup != snapshot.processGroup,
                  !shell.isStopped,
                  !matchedPIDs.contains(shell.pid),
                  !shells.contains(shell.pid)
            else { continue }
            shells.append(shell.pid)
        }

        // Родитель раньше потомков: глубина внутри снимка, а не порядок совпадения.
        let depths: [(pid: Int32, depth: Int)] = active.map { process in
            (pid: process.pid, depth: tree.ancestors(of: process.pid).count)
        }
        let sortedDepths = depths.sorted { lhs, rhs in
            if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
            return lhs.pid < rhs.pid
        }
        let ordered: [Int32] = sortedDepths.map { $0.pid }

        return PausePlan(stopOrder: shells + ordered, shells: shells, backgrounded: backgrounded, skipped: skipped)
    }
}
