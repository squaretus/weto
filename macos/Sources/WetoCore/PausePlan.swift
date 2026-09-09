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

        // Шелл переднего задания: у корня цели есть tty и передний план терминала принадлежит
        // поддереву цели. Шелл — родитель лидера группы цели, он в другой группе (иначе это
        // обёртка, а не шелл) и на том же терминале (иначе он терминал и не отберёт).
        var shells: [Int32] = []
        var backgrounded: [Int32] = []
        for root in active where root.matchedBy == .rule {
            guard let snapshot = byPID[root.pid], snapshot.terminalForegroundGroup != 0 else { continue }
            guard holdsForeground(snapshot, tree: tree) else {
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
                  shell.terminalForegroundGroup == snapshot.terminalForegroundGroup,
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

    /// Цель в переднем плане своего терминала, если лидер передней группы tty — сама цель
    /// или её потомок. Сравнивать группы на равенство нельзя: группу, держащую терминал,
    /// цель могла отдать инструменту, запущенному в собственной группе (`sh -c` → потомок
    /// с `setpgid` + `tcsetpgrp`), и цель при этом остаётся передним заданием шелла. Прежнее
    /// равенство групп объявляло такую цель фоновой, шелл в план не попадал, zsh узнавал
    /// о SIGSTOP цели, печатал `suspended (signal)` и забирал терминал себе — после чего
    /// цель уже действительно становилась фоновым заданием и вставала по `SIGTTIN`.
    ///
    /// Идентификатор группы равен pid её лидера, поэтому лидера ищем по номеру группы.
    /// Лидера может не быть в снимке (успел выйти) — тогда предков у него нет и передний
    /// план поддереву цели не принадлежит.
    private static func holdsForeground(_ target: ProcessSnapshot, tree: ProcessTree) -> Bool {
        if target.processGroup == target.terminalForegroundGroup { return true }
        let foregroundLeader = target.terminalForegroundGroup
        if foregroundLeader == target.pid { return true }
        return tree.ancestors(of: foregroundLeader).contains(target.pid)
    }
}
