import Foundation

public enum ProcessMatcher {

    public static func matches(
        in processes: [ProcessSnapshot],
        rules: [TargetRule]
    ) -> [MatchedProcess] {
        guard !rules.isEmpty else { return [] }

        var seen = Set<Int32>()
        var result: [MatchedProcess] = []
        var nameByRoot: [Int32: String] = [:]

        // Снимок по pid: журналу нужны родитель и путь каждого завершённого
        // процесса, а обход дерева отдаёт одни идентификаторы.
        var snapshotByPID: [Int32: ProcessSnapshot] = [:]
        for process in processes { snapshotByPID[process.pid] = process }

        for process in processes {
            guard let rule = rules.first(where: { matches(process, rule: $0) }) else { continue }
            if seen.insert(process.pid).inserted {
                result.append(MatchedProcess(
                    pid: process.pid,
                    targetName: rule.displayName,
                    parentPID: process.parentPID,
                    executablePath: process.executablePath,
                    isDescendant: false
                ))
                nameByRoot[process.pid] = rule.displayName
            }
        }

        let tree = ProcessTree(processes: processes)
        for descendant in tree.descendants(of: result.map(\.pid), skipping: &seen) {
            guard let name = nameByRoot[descendant.root] else { continue }
            let snapshot = snapshotByPID[descendant.pid]
            result.append(MatchedProcess(
                pid: descendant.pid,
                targetName: name,
                parentPID: snapshot?.parentPID ?? 0,
                executablePath: snapshot?.executablePath ?? "",
                isDescendant: true
            ))
        }
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
        let tree = ProcessTree(processes: processes)

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
            let owner = tree.topmostMatch(of: root.pid, among: rootPIDs)
            ownerByPID[root.pid] = owner
            if owner != root.pid {
                pidsByRoot[owner, default: []].append(root.pid)
                pidsByRoot[root.pid] = nil
            }
        }

        let owners = roots.filter { ownerByPID[$0.pid] == $0.pid }

        for descendant in tree.descendants(of: roots.map(\.pid), skipping: &seen) {
            let owner = ownerByPID[descendant.root] ?? descendant.root
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
            return !Set(arguments).isDisjoint(with: rule.launchPaths)
        }
    }

}
