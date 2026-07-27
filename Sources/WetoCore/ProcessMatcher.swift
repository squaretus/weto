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

        var pidsByRule: [Int: [Int32]] = [:]
        var seen = Set<Int32>()
        var roots: [(pid: Int32, ruleIndex: Int)] = []

        for process in processes {
            guard let index = rules.firstIndex(where: { matches(process, rule: $0) }) else { continue }
            guard seen.insert(process.pid).inserted else { continue }
            pidsByRule[index, default: []].append(process.pid)
            roots.append((process.pid, index))
        }

        for descendant in descendants(of: roots, in: processes, seen: &seen) {
            pidsByRule[descendant.ruleIndex, default: []].append(descendant.pid)
        }

        return rules.indices.compactMap { index in
            guard let pids = pidsByRule[index], let first = pids.min() else { return nil }
            let rule = rules[index]
            return RunningTarget(
                entry: rule.entry,
                displayName: rule.displayName,
                kind: rule.kind,
                path: rule.path,
                pid: first,
                processCount: pids.count
            )
        }
    }

    private static func descendants(
        of roots: [(pid: Int32, ruleIndex: Int)],
        in processes: [ProcessSnapshot],
        seen: inout Set<Int32>
    ) -> [(pid: Int32, ruleIndex: Int)] {
        var childrenByParent: [Int32: [Int32]] = [:]
        for process in processes where process.parentPID > 0 {
            childrenByParent[process.parentPID, default: []].append(process.pid)
        }
        guard !childrenByParent.isEmpty else { return [] }

        var result: [(pid: Int32, ruleIndex: Int)] = []
        var queue = roots
        var steps = 0

        while let parent = queue.popLast(), steps < processes.count * 2 {
            steps += 1
            for child in childrenByParent[parent.pid] ?? [] where seen.insert(child).inserted {
                let matched = (pid: child, ruleIndex: parent.ruleIndex)
                result.append(matched)
                queue.append(matched)
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
