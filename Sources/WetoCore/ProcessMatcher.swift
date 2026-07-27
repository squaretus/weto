import Foundation

public enum ProcessMatcher {

    public static func matches(
        in processes: [ProcessSnapshot],
        rules: [TargetRule]
    ) -> [MatchedProcess] {
        guard !rules.isEmpty else { return [] }

        var seen = Set<Int32>()
        var result: [MatchedProcess] = []

        for process in processes {
            guard let rule = rules.first(where: { matches(process, rule: $0) }) else { continue }
            if seen.insert(process.pid).inserted {
                result.append(MatchedProcess(pid: process.pid, targetName: rule.displayName))
            }
        }

        result.append(contentsOf: descendants(of: result, in: processes, seen: &seen))
        return result
    }

    public static func pids(
        in processes: [ProcessSnapshot],
        rules: [TargetRule]
    ) -> [Int32] {
        matches(in: processes, rules: rules).map(\.pid)
    }

    public static func runningTargets(
        in processes: [ProcessSnapshot],
        rules: [TargetRule]
    ) -> [RunningTarget] {
        guard !rules.isEmpty else { return [] }

        var childrenByParent: [Int32: [Int32]] = [:]
        var parentByPID: [Int32: Int32] = [:]
        for process in processes {
            parentByPID[process.pid] = process.parentPID
            if process.parentPID > 0 {
                childrenByParent[process.parentPID, default: []].append(process.pid)
            }
        }

        var roots: [(process: ProcessSnapshot, rule: TargetRule)] = []
        var rootPIDs = Set<Int32>()

        for process in processes {
            guard let rule = rules.first(where: { matches(process, rule: $0) }) else { continue }
            guard rootPIDs.insert(process.pid).inserted else { continue }
            roots.append((process, rule))
        }

        // Процесс, чей предок уже цель, — это потомок, а не отдельная строка виджета.
        let nested = Set(
            roots
                .map(\.process)
                .filter { hasAncestor(in: rootPIDs, of: $0, parentByPID: parentByPID) }
                .map(\.pid)
        )

        return roots
            .filter { !nested.contains($0.process.pid) }
            .map { root in
                RunningTarget(
                    entry: root.rule.entry,
                    displayName: root.rule.displayName,
                    kind: root.rule.kind,
                    path: root.rule.path,
                    pid: root.process.pid,
                    childCount: descendantCount(of: root.process.pid, childrenByParent: childrenByParent)
                )
            }
    }

    private static func hasAncestor(
        in pids: Set<Int32>,
        of process: ProcessSnapshot,
        parentByPID: [Int32: Int32]
    ) -> Bool {
        var current = process.parentPID
        var steps = 0
        while current > 0, current != process.pid, steps < parentByPID.count {
            if pids.contains(current) { return true }
            current = parentByPID[current] ?? 0
            steps += 1
        }
        return false
    }

    private static func descendantCount(
        of pid: Int32,
        childrenByParent: [Int32: [Int32]]
    ) -> Int {
        var count = 0
        var queue = childrenByParent[pid] ?? []
        var visited = Set<Int32>()

        while let next = queue.popLast() {
            guard visited.insert(next).inserted else { continue }
            count += 1
            queue.append(contentsOf: childrenByParent[next] ?? [])
        }
        return count
    }

    private static func matches(_ process: ProcessSnapshot, rule: TargetRule) -> Bool {
        switch rule.kind {
        case .appBundle:

            var prefix = rule.path
            while prefix.hasSuffix("/") { prefix.removeLast() }
            return process.executablePath.hasPrefix(prefix + "/")
        case .binary:
            return process.executablePath == rule.path
        case .script:
            return process.arguments?.contains(rule.path) ?? false
        }
    }

    private static func descendants(
        of roots: [MatchedProcess],
        in processes: [ProcessSnapshot],
        seen: inout Set<Int32>
    ) -> [MatchedProcess] {
        var childrenByParent: [Int32: [ProcessSnapshot]] = [:]
        for process in processes where process.parentPID > 0 {
            childrenByParent[process.parentPID, default: []].append(process)
        }
        guard !childrenByParent.isEmpty else { return [] }

        var result: [MatchedProcess] = []
        var queue = roots

        var steps = 0
        while let parent = queue.popLast(), steps < processes.count * 2 {
            steps += 1
            for child in childrenByParent[parent.pid] ?? [] where seen.insert(child.pid).inserted {
                let matched = MatchedProcess(pid: child.pid, targetName: parent.targetName)
                result.append(matched)
                queue.append(matched)
            }
        }
        return result
    }
}
