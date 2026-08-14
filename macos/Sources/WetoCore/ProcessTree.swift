import Foundation

/// Дерево процессов снимка: строится один раз и обслуживает и подбор целей,
/// и построение списка живых сеансов. Раньше обход потомков существовал в двух
/// почти одинаковых копиях с собственной защитой от циклов.
public struct ProcessTree {

    private let childrenByParent: [Int32: [Int32]]
    private let parentByPID: [Int32: Int32]
    private let stepLimit: Int

    public init(processes: [ProcessSnapshot]) {
        var children: [Int32: [Int32]] = [:]
        var parents: [Int32: Int32] = [:]

        for process in processes {
            parents[process.pid] = process.parentPID
            guard process.parentPID > 0 else { continue }
            children[process.parentPID, default: []].append(process.pid)
        }

        self.childrenByParent = children
        self.parentByPID = parents
        self.stepLimit = processes.count * 2
    }

    /// Потомки указанных корней. `seen` защищает и от повторов, и от циклов
    /// в дереве, где родитель ссылается на своего же потомка.
    public func descendants(
        of roots: [Int32],
        skipping seen: inout Set<Int32>
    ) -> [(pid: Int32, root: Int32)] {
        guard !childrenByParent.isEmpty else { return [] }

        var result: [(pid: Int32, root: Int32)] = []
        var queue = roots.map { (pid: $0, root: $0) }
        var steps = 0

        while let current = queue.popLast(), steps < stepLimit {
            steps += 1
            for child in childrenByParent[current.pid] ?? [] where seen.insert(child).inserted {
                result.append((pid: child, root: current.root))
                queue.append((pid: child, root: current.root))
            }
        }
        return result
    }

    /// Самый верхний предок, который сам является совпавшим процессом.
    /// Нужен, чтобы совпавший потомок не выглядел отдельным сеансом.
    public func topmostMatch(of pid: Int32, among matched: Set<Int32>) -> Int32 {
        var owner = pid
        var current = parentByPID[pid] ?? 0
        var steps = 0

        while current > 0, current != pid, steps < parentByPID.count {
            if matched.contains(current) { owner = current }
            current = parentByPID[current] ?? 0
            steps += 1
        }
        return owner
    }
}
