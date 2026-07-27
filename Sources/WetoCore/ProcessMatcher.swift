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

        var seen = Set<Int32>()
        var roots: [(pid: Int32, ruleIndex: Int)] = []
        var pidsByRoot: [Int32: [Int32]] = [:]
        var parentByPID: [Int32: Int32] = [:]

        for process in processes { parentByPID[process.pid] = process.parentPID }

        for process in processes {
            guard let index = rules.firstIndex(where: { matches(process, rule: $0) }) else { continue }
            guard seen.insert(process.pid).inserted else { continue }
            roots.append((process.pid, index))
            pidsByRoot[process.pid] = [process.pid]
        }

        // Совпавший процесс под совпавшим родителем — часть того же сеанса, а не новый.
        let rootPIDs = Set(roots.map(\.pid))
        var ownerByPID: [Int32: Int32] = [:]
        for root in roots {
            let owner = topmostMatch(of: root.pid, among: rootPIDs, parentByPID: parentByPID)
            ownerByPID[root.pid] = owner
            if owner != root.pid {
                pidsByRoot[owner, default: []].append(root.pid)
                pidsByRoot[root.pid] = nil
            }
        }

        let owners = roots.filter { ownerByPID[$0.pid] == $0.pid }

        for descendant in descendants(of: roots, in: processes, seen: &seen) {
            let owner = ownerByPID[descendant.parent] ?? descendant.parent
            pidsByRoot[owner, default: []].append(descendant.pid)
        }

        return owners.flatMap { owner -> [RunningTarget] in
            let rule = rules[owner.ruleIndex]
            let pids = pidsByRoot[owner.pid] ?? [owner.pid]
            return [
                RunningTarget(
                    entry: rule.entry,
                    displayName: rule.displayName,
                    kind: rule.kind,
                    path: rule.path,
                    pid: owner.pid,
                    processCount: pids.count
                )
            ]
        }
        .reduce(into: [RunningTarget]()) { result, target in
            // Приложение живёт одной строкой: его хелперы стартуют от launchd
            // и выглядят как самостоятельные корни.
            guard target.kind == .appBundle else {
                result.append(target)
                return
            }
            if let existing = result.firstIndex(where: { $0.entry == target.entry }) {
                let merged = result[existing]
                result[existing] = RunningTarget(
                    entry: merged.entry,
                    displayName: merged.displayName,
                    kind: merged.kind,
                    path: merged.path,
                    pid: min(merged.pid, target.pid),
                    processCount: merged.processCount + target.processCount
                )
            } else {
                result.append(target)
            }
        }
    }

    private static func topmostMatch(
        of pid: Int32,
        among matched: Set<Int32>,
        parentByPID: [Int32: Int32]
    ) -> Int32 {
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

    private static func descendants(
        of roots: [(pid: Int32, ruleIndex: Int)],
        in processes: [ProcessSnapshot],
        seen: inout Set<Int32>
    ) -> [(pid: Int32, ruleIndex: Int, parent: Int32)] {
        var childrenByParent: [Int32: [Int32]] = [:]
        for process in processes where process.parentPID > 0 {
            childrenByParent[process.parentPID, default: []].append(process.pid)
        }
        guard !childrenByParent.isEmpty else { return [] }

        var result: [(pid: Int32, ruleIndex: Int, parent: Int32)] = []
        var queue = roots.map { (pid: $0.pid, ruleIndex: $0.ruleIndex, owner: $0.pid) }
        var steps = 0

        while let parent = queue.popLast(), steps < processes.count * 2 {
            steps += 1
            for child in childrenByParent[parent.pid] ?? [] where seen.insert(child).inserted {
                result.append((pid: child, ruleIndex: parent.ruleIndex, parent: parent.owner))
                queue.append((pid: child, ruleIndex: parent.ruleIndex, owner: parent.owner))
            }
        }
        return result
    }

    private static func matches(_ process: ProcessSnapshot, rule: TargetRule) -> Bool {
        switch rule.kind {
        case .appBundle:

            var prefix = rule.path
            while prefix.hasSuffix("/") { prefix.removeLast() }
            return process.executablePath.hasPrefix(prefix + "/")
        case .binary:
            return rule.launchPaths.contains(process.executablePath)
        case .script:
            guard let arguments = process.arguments else { return false }
            return rule.launchPaths.contains { arguments.contains($0) }
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
