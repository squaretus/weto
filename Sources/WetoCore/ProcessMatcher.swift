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
