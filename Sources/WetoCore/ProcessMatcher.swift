import Foundation

/// Отбор процессов, принадлежащих целям. Чистая функция.
public enum ProcessMatcher {

    /// Процессы целей вместе с их потомками.
    ///
    /// Потомки нужны потому, что цель редко живёт одна: она порождает хелперы
    /// и вспомогательные утилиты. Оставить их после смерти родителя — значит
    /// оставить работающие сетевые соединения, ради закрытия которых всё
    /// и затевалось. Потомок наследует имя цели предка, чтобы в журнале было
    /// видно, из-за чего он погиб.
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

    /// Совместимость с точечными проверками: только pid, без имён.
    public static func pids(
        in processes: [ProcessSnapshot],
        rules: [TargetRule]
    ) -> [Int32] {
        matches(in: processes, rules: rules).map(\.pid)
    }

    // MARK: - Private

    private static func matches(_ process: ProcessSnapshot, rule: TargetRule) -> Bool {
        switch rule.kind {
        case .appBundle:
            // Префикс с обязательным разделителем на границе, иначе
            // `/Applications/TargetExtra.app` попал бы в `/Applications/Target.app`.
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
        // Ограничение шагов — страховка от цикла в дереве: при гонке между
        // перечислением и переиспользованием pid возможен самоссылающийся родитель.
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
