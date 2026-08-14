//! Отбор процессов-целей и обход дерева потомков.
//!
//! Порт `ProcessMatcher` и `ProcessTree`. Из макосных видов цели здесь остаются
//! два: `Binary` и `Script`. Вид `appBundle` не переносится — на Linux нет
//! бандла приложения, каталогом которого можно было бы накрыть все процессы
//! сразу; ярлык `.desktop` указывает на обычный бинарник, то есть это `Binary`.

use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProcessSnapshot {
    pub pid: i32,
    pub parent_pid: i32,
    /// Путь уже разрешён ядром: `readlink /proc/<pid>/exe` возвращает конечный
    /// файл, поэтому макосная ловушка «nano — симлинк на pico» здесь не возникает.
    pub executable_path: String,
    /// argv как есть. У скрипта с shebang `exe` указывает на интерпретатор,
    /// и опознать цель можно только отсюда.
    pub arguments: Option<Vec<String>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TargetKind {
    Binary,
    Script,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TargetRule {
    pub entry: String,
    pub display_name: String,
    pub kind: TargetKind,
    pub path: String,
    /// Пути, по которым цель может встретиться: сам путь запуска (обычно симлинк
    /// в `$PATH`) и всё, во что он разворачивается.
    pub launch_paths: Vec<String>,
}

impl TargetRule {
    pub fn new(
        entry: &str,
        display_name: &str,
        kind: TargetKind,
        path: &str,
        launch_paths: &[&str],
    ) -> TargetRule {
        let mut paths = vec![path.to_string()];
        for candidate in launch_paths {
            if !paths.iter().any(|p| p == candidate) {
                paths.push((*candidate).to_string());
            }
        }
        TargetRule {
            entry: entry.to_string(),
            display_name: display_name.to_string(),
            kind,
            path: path.to_string(),
            launch_paths: paths,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MatchedProcess {
    pub pid: i32,
    pub target_name: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunningTarget {
    pub entry: String,
    pub display_name: String,
    pub kind: TargetKind,
    pub path: String,
    pub pid: i32,
    pub process_count: usize,
}

impl RunningTarget {
    pub fn extra_process_count(&self) -> usize {
        self.process_count.saturating_sub(1)
    }
}

/// Дерево процессов снимка: строится один раз и обслуживает и подбор целей,
/// и построение списка живых сеансов.
pub struct ProcessTree {
    children_by_parent: HashMap<i32, Vec<i32>>,
    parent_by_pid: HashMap<i32, i32>,
    step_limit: usize,
}

impl ProcessTree {
    pub fn new(processes: &[ProcessSnapshot]) -> ProcessTree {
        let mut children_by_parent: HashMap<i32, Vec<i32>> = HashMap::new();
        let mut parent_by_pid: HashMap<i32, i32> = HashMap::new();

        for process in processes {
            parent_by_pid.insert(process.pid, process.parent_pid);
            if process.parent_pid > 0 {
                children_by_parent
                    .entry(process.parent_pid)
                    .or_default()
                    .push(process.pid);
            }
        }

        ProcessTree {
            children_by_parent,
            parent_by_pid,
            step_limit: processes.len() * 2,
        }
    }

    /// Потомки указанных корней. `seen` защищает и от повторов, и от циклов
    /// в дереве, где родитель ссылается на своего же потомка.
    pub fn descendants(&self, roots: &[i32], seen: &mut HashSet<i32>) -> Vec<(i32, i32)> {
        if self.children_by_parent.is_empty() {
            return Vec::new();
        }

        let mut result = Vec::new();
        let mut queue: Vec<(i32, i32)> = roots.iter().map(|pid| (*pid, *pid)).collect();
        let mut steps = 0usize;

        while let Some((pid, root)) = queue.pop() {
            if steps >= self.step_limit {
                break;
            }
            steps += 1;
            for child in self.children_by_parent.get(&pid).into_iter().flatten() {
                if seen.insert(*child) {
                    result.push((*child, root));
                    queue.push((*child, root));
                }
            }
        }
        result
    }

    /// Самый верхний предок, который сам является совпавшим процессом.
    /// Нужен, чтобы совпавший потомок не выглядел отдельным сеансом.
    pub fn topmost_match(&self, pid: i32, matched: &HashSet<i32>) -> i32 {
        let mut owner = pid;
        let mut current = self.parent_by_pid.get(&pid).copied().unwrap_or(0);
        let mut steps = 0usize;

        while current > 0 && current != pid && steps < self.parent_by_pid.len() {
            if matched.contains(&current) {
                owner = current;
            }
            current = self.parent_by_pid.get(&current).copied().unwrap_or(0);
            steps += 1;
        }
        owner
    }
}

fn matches_rule(process: &ProcessSnapshot, rule: &TargetRule) -> bool {
    match rule.kind {
        TargetKind::Binary => rule.launch_paths.contains(&process.executable_path),
        TargetKind::Script => {
            // Поэлементно, а не подстрокой: подстрочное сравнение убивало обёртки
            // с похожим именем и процессы, у которых путь цели встретился
            // в данных команды.
            let Some(arguments) = &process.arguments else {
                return false;
            };
            arguments
                .iter()
                .any(|argument| rule.launch_paths.contains(argument))
        }
    }
}

pub fn matches(processes: &[ProcessSnapshot], rules: &[TargetRule]) -> Vec<MatchedProcess> {
    if rules.is_empty() {
        return Vec::new();
    }

    let mut seen: HashSet<i32> = HashSet::new();
    let mut result: Vec<MatchedProcess> = Vec::new();
    let mut name_by_root: HashMap<i32, String> = HashMap::new();

    for process in processes {
        let Some(rule) = rules.iter().find(|rule| matches_rule(process, rule)) else {
            continue;
        };
        if seen.insert(process.pid) {
            result.push(MatchedProcess {
                pid: process.pid,
                target_name: rule.display_name.clone(),
            });
            name_by_root.insert(process.pid, rule.display_name.clone());
        }
    }

    let tree = ProcessTree::new(processes);
    let roots: Vec<i32> = result.iter().map(|m| m.pid).collect();
    for (pid, root) in tree.descendants(&roots, &mut seen) {
        if let Some(name) = name_by_root.get(&root) {
            result.push(MatchedProcess {
                pid,
                target_name: name.clone(),
            });
        }
    }
    result
}

pub fn pids(processes: &[ProcessSnapshot], rules: &[TargetRule]) -> Vec<i32> {
    matches(processes, rules)
        .into_iter()
        .map(|m| m.pid)
        .collect()
}

/// Живые цели по одной строке на цель, а не на процесс.
pub fn running_targets(processes: &[ProcessSnapshot], rules: &[TargetRule]) -> Vec<RunningTarget> {
    if rules.is_empty() {
        return Vec::new();
    }

    let mut seen: HashSet<i32> = HashSet::new();
    let mut roots: Vec<(i32, usize)> = Vec::new();
    let mut pids_by_root: HashMap<i32, Vec<i32>> = HashMap::new();
    let tree = ProcessTree::new(processes);

    for process in processes {
        let Some(index) = rules.iter().position(|rule| matches_rule(process, rule)) else {
            continue;
        };
        if !seen.insert(process.pid) {
            continue;
        }
        roots.push((process.pid, index));
        pids_by_root.insert(process.pid, vec![process.pid]);
    }

    // Совпавший процесс под совпавшим родителем — часть того же сеанса, а не новый.
    let root_pids: HashSet<i32> = roots.iter().map(|(pid, _)| *pid).collect();
    let mut owner_by_pid: HashMap<i32, i32> = HashMap::new();
    for (pid, _) in &roots {
        let owner = tree.topmost_match(*pid, &root_pids);
        owner_by_pid.insert(*pid, owner);
        if owner != *pid {
            pids_by_root.entry(owner).or_default().push(*pid);
            pids_by_root.remove(pid);
        }
    }

    let root_list: Vec<i32> = roots.iter().map(|(pid, _)| *pid).collect();
    for (pid, root) in tree.descendants(&root_list, &mut seen) {
        let owner = owner_by_pid.get(&root).copied().unwrap_or(root);
        pids_by_root.entry(owner).or_default().push(pid);
    }

    roots
        .iter()
        .filter(|(pid, _)| owner_by_pid.get(pid) == Some(pid))
        .map(|(pid, rule_index)| {
            let rule = &rules[*rule_index];
            let count = pids_by_root.get(pid).map(Vec::len).unwrap_or(1);
            RunningTarget {
                entry: rule.entry.clone(),
                display_name: rule.display_name.clone(),
                kind: rule.kind,
                path: rule.path.clone(),
                pid: *pid,
                process_count: count,
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn process(pid: i32, parent: i32, exe: &str, argv: &[&str]) -> ProcessSnapshot {
        ProcessSnapshot {
            pid,
            parent_pid: parent,
            executable_path: exe.to_string(),
            arguments: if argv.is_empty() {
                None
            } else {
                Some(argv.iter().map(|a| (*a).to_string()).collect())
            },
        }
    }

    fn binary(path: &str) -> TargetRule {
        TargetRule::new(path, path, TargetKind::Binary, path, &[])
    }

    fn script(path: &str, launch_paths: &[&str]) -> TargetRule {
        TargetRule::new(path, path, TargetKind::Script, path, launch_paths)
    }

    #[test]
    fn binary_is_matched_by_exact_resolved_path() {
        let procs = vec![
            process(10, 1, "/usr/bin/nano", &["nano"]),
            process(11, 1, "/usr/bin/nano-helper", &["nano-helper"]),
        ];
        assert_eq!(pids(&procs, &[binary("/usr/bin/nano")]), vec![10]);
    }

    #[test]
    fn empty_rule_list_matches_nothing() {
        let procs = vec![process(10, 1, "/usr/bin/nano", &["nano"])];
        assert!(pids(&procs, &[]).is_empty());
    }

    #[test]
    fn script_is_matched_by_command_line_not_by_interpreter() {
        let rule = script("/usr/local/bin/qwen", &[]);
        let procs = vec![
            process(
                10,
                1,
                "/usr/bin/node",
                &["node", "/usr/local/bin/qwen", "--chat"],
            ),
            process(11, 1, "/usr/bin/node", &["node", "/usr/local/bin/other"]),
        ];
        assert_eq!(
            pids(&procs, &[rule]),
            vec![10],
            "матчинг по пути интерпретатора выкосил бы все процессы Node"
        );
    }

    #[test]
    fn script_path_must_equal_one_argv_element() {
        let rule = script("/usr/local/bin/qwen", &[]);
        let wrapper = process(
            11,
            1,
            "/usr/bin/node",
            &["node", "/usr/local/bin/qwen-helper"],
        );
        let data = process(
            12,
            1,
            "/usr/bin/grep",
            &["grep", "-r", "/usr/local/bin/qwen", "/var/log"],
        );

        assert!(
            pids(&[wrapper], std::slice::from_ref(&rule)).is_empty(),
            "подстрочное сравнение убивало обёртку с похожим именем"
        );
        assert_eq!(
            pids(&[data], &[rule]),
            vec![12],
            "путь целиком отдельным аргументом — это совпадение, даже если это данные"
        );
    }

    #[test]
    fn script_rule_ignores_processes_without_arguments() {
        let rule = script("/usr/local/bin/qwen", &[]);
        let procs = vec![process(10, 1, "/usr/bin/node", &[])];
        assert!(pids(&procs, &[rule]).is_empty());
    }

    #[test]
    fn script_is_matched_by_the_symlink_it_was_launched_with() {
        let rule = script("/opt/qwen/bin/qwen.js", &["/usr/local/bin/qwen"]);
        let procs = vec![process(
            10,
            1,
            "/usr/bin/node",
            &["node", "/usr/local/bin/qwen"],
        )];
        assert_eq!(pids(&procs, &[rule]), vec![10]);
    }

    #[test]
    fn children_of_a_matched_process_are_included_with_parent_name() {
        let procs = vec![
            process(20, 1, "/usr/bin/nano", &["nano"]),
            process(21, 20, "/usr/bin/sh", &["sh"]),
            process(22, 1, "/usr/bin/sh", &["sh"]),
        ];
        let matched = matches(&procs, &[binary("/usr/bin/nano")]);
        assert_eq!(matched.len(), 2);
        assert_eq!(matched[1].pid, 21);
        assert_eq!(matched[1].target_name, "/usr/bin/nano");
    }

    #[test]
    fn grandchildren_are_included() {
        let procs = vec![
            process(20, 1, "/usr/bin/nano", &["nano"]),
            process(21, 20, "/usr/bin/sh", &["sh"]),
            process(22, 21, "/usr/bin/cat", &["cat"]),
        ];
        let mut result = pids(&procs, &[binary("/usr/bin/nano")]);
        result.sort();
        assert_eq!(result, vec![20, 21, 22]);
    }

    #[test]
    fn cycle_in_process_tree_does_not_hang() {
        let procs = vec![
            process(20, 21, "/usr/bin/nano", &["nano"]),
            process(21, 20, "/usr/bin/sh", &["sh"]),
        ];
        let mut result = pids(&procs, &[binary("/usr/bin/nano")]);
        result.sort();
        assert_eq!(result, vec![20, 21]);
    }

    #[test]
    fn zero_parent_pid_does_not_create_a_phantom_root() {
        let procs = vec![
            process(20, 0, "/usr/bin/nano", &["nano"]),
            process(21, 0, "/usr/bin/sh", &["sh"]),
        ];
        assert_eq!(pids(&procs, &[binary("/usr/bin/nano")]), vec![20]);
    }

    #[test]
    fn running_targets_report_one_row_per_target_with_process_count() {
        let procs = vec![
            process(20, 1, "/usr/bin/nano", &["nano"]),
            process(21, 20, "/usr/bin/sh", &["sh"]),
        ];
        let targets = running_targets(&procs, &[binary("/usr/bin/nano")]);
        assert_eq!(targets.len(), 1);
        assert_eq!(targets[0].pid, 20);
        assert_eq!(targets[0].process_count, 2);
        assert_eq!(targets[0].extra_process_count(), 1);
    }

    #[test]
    fn two_separate_sessions_stay_two_rows() {
        let procs = vec![
            process(20, 1, "/usr/bin/nano", &["nano"]),
            process(30, 1, "/usr/bin/nano", &["nano"]),
        ];
        let targets = running_targets(&procs, &[binary("/usr/bin/nano")]);
        assert_eq!(targets.len(), 2);
    }

    #[test]
    fn nested_session_of_the_same_tool_joins_its_parent() {
        let procs = vec![
            process(20, 1, "/usr/bin/nano", &["nano"]),
            process(21, 20, "/usr/bin/sh", &["sh"]),
            process(22, 21, "/usr/bin/nano", &["nano"]),
        ];
        let targets = running_targets(&procs, &[binary("/usr/bin/nano")]);
        assert_eq!(
            targets.len(),
            1,
            "вложенный сеанс — часть того же, а не новый"
        );
        assert_eq!(targets[0].pid, 20);
        assert_eq!(targets[0].process_count, 3);
    }

    #[test]
    fn running_targets_are_empty_without_matching_processes() {
        let procs = vec![process(20, 1, "/usr/bin/vim", &["vim"])];
        assert!(running_targets(&procs, &[binary("/usr/bin/nano")]).is_empty());
    }

    #[test]
    fn running_targets_survive_a_cycle_in_the_tree() {
        let procs = vec![
            process(20, 21, "/usr/bin/nano", &["nano"]),
            process(21, 20, "/usr/bin/sh", &["sh"]),
        ];
        let targets = running_targets(&procs, &[binary("/usr/bin/nano")]);
        assert_eq!(targets.len(), 1);
    }

    #[test]
    fn first_matching_rule_wins_for_naming() {
        let procs = vec![process(10, 1, "/usr/bin/nano", &["nano"])];
        let rules = vec![
            TargetRule::new("first", "Первая", TargetKind::Binary, "/usr/bin/nano", &[]),
            TargetRule::new("second", "Вторая", TargetKind::Binary, "/usr/bin/nano", &[]),
        ];
        assert_eq!(matches(&procs, &rules)[0].target_name, "Первая");
    }
}
