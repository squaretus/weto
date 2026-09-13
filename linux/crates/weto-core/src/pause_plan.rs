//! Кому и в каком порядке слать SIGSTOP — чистое вычисление по снимку процессов.
//!
//! Порт `macos/Sources/WetoCore/PausePlan.swift`. Порядок — часть контракта границы
//! сигналов: шелл раньше своей цели, родитель раньше потомков; продолжение —
//! строго наоборот. Иначе шелл забирает терминал себе обратно, и цель встаёт
//! по `SIGTTIN`. Проверено на zsh и bash.
//!
//! Данные сюда приходят готовым снимком: ни `/proc`, ни сигналов здесь нет —
//! их шлёт граница, получив этот план.

use std::collections::{HashMap, HashSet};

use crate::process::{MatchBasis, MatchedProcess, ProcessSnapshot, ProcessTree};

/// Шеллы, которые ведут job control. Список имён — неприятная, но единственная
/// работающая проверка: структурно родитель-`login` под эмулятором терминала
/// и интерактивный zsh под `script`/tmux стоят на одном и том же месте дерева.
/// У обоих родитель сидит на том же tty, в своей группе процессов, и оба —
/// лидеры своей сессии, так что «не лидер сессии» выкинуло бы из плана как раз
/// нужный шелл, а группы и tty не разводят эти формы вовсе.
///
/// Разводит их работа: терминал у остановленной цели отбирает тот, кто ведёт её
/// задание, а `login` лишь ждёт выхода шелла — ему SIGSTOP не по делу.
/// Незнакомый шелл кандидатом не станет, и цель под ним уйдёт в фон на первой
/// же паузе; расплата видна — учёт держит обязательство до наблюдения,
/// и пользователь получает подсказку про `fg`.
pub const SHELL_NAMES: &[&str] = &[
    "sh", "bash", "dash", "zsh", "ksh", "ksh93", "mksh", "csh", "tcsh", "fish", "nu", "nushell",
    "xonsh", "elvish", "pwsh",
];

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PausePlan {
    pub stop_order: Vec<i32>,

    /// Шеллы, вошедшие в план ради терминала. Они не цели — но SIGSTOP получают,
    /// а значит, журнал обязан их объяснить: запись заводится с `MatchBasis::Shell`
    /// в том же эпизоде, что и цели, ради которых шелл остановлен.
    pub shells: Vec<i32>,

    /// Ради чьего терминала шелл вошёл в план: имя цели у записи журнала берётся отсюда,
    /// иначе шелл остался бы в журнале безымянным процессом без связи с целью.
    pub shell_targets: HashMap<i32, String>,

    /// Корни целей, которым терминал после SIGCONT не вернуть: фоновое задание.
    /// Пользователю об этом говорит интерфейс (подсказка про `fg`).
    pub backgrounded: Vec<i32>,

    /// Стояли до нас (Ctrl-Z): не трогаем ни при паузе, ни при возобновлении.
    pub skipped: Vec<i32>,
}

impl PausePlan {
    pub fn resume_order(&self) -> Vec<i32> {
        self.stop_order.iter().rev().copied().collect()
    }

    pub fn is_empty(&self) -> bool {
        self.stop_order.is_empty()
    }
}

/// Стоящая цель — то, что интерфейс показывает пилюлей с отсчётом. Порт
/// `PausedProcess` с macOS: там же лежит и правило про `is_backgrounded` —
/// признак дописывает наблюдение, а не догадка плана паузы.
///
/// Шеллы сюда не попадают: они получили SIGSTOP ради терминала цели, объяснены
/// журналом, но целями не являются и пилюли не заводят.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PausedProcess {
    pub pid: i32,
    pub target_name: String,
    /// Когда цель встала. У восстановленной с прошлого запуска — момент из учёта,
    /// а не «сейчас»: стоит она с прошлой жизни weto.
    pub since: std::time::SystemTime,
    /// Терминал цели забрал шелл: SIGCONT её не поднимет, нужен `fg`.
    pub is_backgrounded: bool,
}

/// Процесс, застигнутый стоящим на старте: учёт пережил падение weto.
///
/// Момент едет отдельным полем, потому что запись журнала датируется тем, когда
/// процесс встал, а не тем, когда weto это заметил: стоит он с прошлой жизни,
/// и «сейчас» в журнале было бы неправдой.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecoveredProcess {
    pub process: MatchedProcess,
    pub stopped_at: std::time::SystemTime,
}

pub fn plan(matched: &[MatchedProcess], processes: &[ProcessSnapshot]) -> PausePlan {
    let by_pid: HashMap<i32, &ProcessSnapshot> = processes.iter().map(|p| (p.pid, p)).collect();
    let tree = ProcessTree::new(processes);
    let matched_pids: HashSet<i32> = matched.iter().map(|m| m.pid).collect();

    let mut skipped: Vec<i32> = Vec::new();
    let mut active: Vec<&MatchedProcess> = Vec::new();
    for process in matched {
        if by_pid.get(&process.pid).is_some_and(|p| p.is_stopped) {
            skipped.push(process.pid);
        } else {
            active.push(process);
        }
    }

    // Шелл переднего задания: у корня цели есть tty и передний план терминала принадлежит
    // поддереву цели. Шелл — родитель лидера группы цели, он в другой группе (иначе это
    // обёртка, а не шелл), на том же терминале (иначе он терминал и не отберёт)
    // и действительно шелл (иначе это `login`, терминал у цели не отбирающий).
    let mut shells: Vec<i32> = Vec::new();
    let mut shell_targets: HashMap<i32, String> = HashMap::new();
    let mut backgrounded: Vec<i32> = Vec::new();
    for root in active.iter().filter(|m| m.matched_by == MatchBasis::Rule) {
        let Some(snapshot) = by_pid.get(&root.pid) else {
            continue;
        };
        if snapshot.terminal_foreground_group == 0 {
            continue;
        }
        if !holds_foreground(snapshot, &tree) {
            backgrounded.push(root.pid);
            continue;
        }
        // Лидер группы обычно и есть сама цель. Если лидер уже вышел и в снимке его нет,
        // намеренно считаем root'а собственным лидером: родителя-шелла всё равно ищем
        // через parent_pid, а не через факт лидерства, так что отсутствие лидера в снимке
        // на поиск шелла не влияет.
        let leader = by_pid
            .get(&snapshot.process_group)
            .copied()
            .unwrap_or(snapshot);
        let Some(shell) = by_pid.get(&leader.parent_pid) else {
            continue;
        };
        if shell.process_group == snapshot.process_group
            || shell.terminal_foreground_group != snapshot.terminal_foreground_group
            || !is_shell(shell)
            || shell.is_stopped
            || matched_pids.contains(&shell.pid)
            || shells.contains(&shell.pid)
        {
            continue;
        }
        shells.push(shell.pid);
        // Терминал у шелла один, и цель в нём тоже одна: первая же выигрывает имя,
        // и повтора здесь не бывает — `shells.contains` выше отсекает второй заход.
        shell_targets.insert(shell.pid, root.target_name.clone());
    }

    // Родитель раньше потомков: глубина внутри снимка, а не порядок совпадения.
    let mut depths: Vec<(i32, usize)> = active
        .iter()
        .map(|process| (process.pid, tree.ancestors(process.pid).len()))
        .collect();
    depths.sort_by(|left, right| left.1.cmp(&right.1).then(left.0.cmp(&right.0)));

    let mut stop_order = shells.clone();
    stop_order.extend(depths.into_iter().map(|(pid, _)| pid));

    PausePlan {
        stop_order,
        shells,
        shell_targets,
        backgrounded,
        skipped,
    }
}

/// Цель в переднем плане своего терминала, если лидер передней группы tty — сама цель
/// или её потомок. Сравнивать группы на равенство нельзя: группу, держащую терминал,
/// цель могла отдать инструменту, запущенному в собственной группе (`setpgid` +
/// `tcsetpgrp`), и цель при этом остаётся передним заданием шелла. Прежнее равенство
/// групп объявляло такую цель фоновой, шелл в план не попадал, zsh узнавал о SIGSTOP
/// цели, печатал `suspended (signal)` и забирал терминал себе — после чего цель уже
/// действительно становилась фоновым заданием и вставала по `SIGTTIN`.
///
/// Идентификатор группы равен pid её лидера, поэтому лидера ищем по номеру группы.
/// Отдельной ветки «лидер передней группы — сама цель» нет: группа зовётся по pid
/// своего лидера, так что этот случай — то же равенство групп сверху. Лидера может
/// не быть в снимке (успел выйти) — тогда предков у него нет и передний план
/// поддереву цели не принадлежит.
fn holds_foreground(target: &ProcessSnapshot, tree: &ProcessTree) -> bool {
    if target.process_group == target.terminal_foreground_group {
        return true;
    }
    tree.ancestors(target.terminal_foreground_group)
        .contains(&target.pid)
}

fn is_shell(process: &ProcessSnapshot) -> bool {
    let Some(name) = process.executable_path.rsplit('/').next() else {
        return false;
    };
    SHELL_NAMES.contains(&name)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// zsh (pid 100, своя группа 100, tty в переднем плане у группы 200) → claude (200,
    /// лидер группы 200) → node (201, потомок в той же группе).
    fn shell() -> ProcessSnapshot {
        snapshot(100, 1, "/bin/zsh", 100, 200)
    }

    fn claude() -> ProcessSnapshot {
        snapshot(200, 100, "/home/me/.local/bin/claude", 200, 200)
    }

    fn child() -> ProcessSnapshot {
        snapshot(201, 200, "/usr/bin/node", 200, 200)
    }

    fn snapshot(
        pid: i32,
        parent_pid: i32,
        executable_path: &str,
        process_group: i32,
        terminal_foreground_group: i32,
    ) -> ProcessSnapshot {
        ProcessSnapshot {
            pid,
            parent_pid,
            executable_path: executable_path.to_string(),
            process_group,
            terminal_foreground_group,
            ..ProcessSnapshot::default()
        }
    }

    /// Без tty: GUI-процесс или демон.
    fn detached(pid: i32, parent_pid: i32, executable_path: &str) -> ProcessSnapshot {
        snapshot(pid, parent_pid, executable_path, 0, 0)
    }

    fn matched(pids: &[(i32, MatchBasis)]) -> Vec<MatchedProcess> {
        pids.iter()
            .map(|(pid, basis)| MatchedProcess {
                pid: *pid,
                target_name: "claude".to_string(),
                parent_pid: 0,
                executable_path: String::new(),
                matched_by: *basis,
            })
            .collect()
    }

    /// Стоп — шелл, цель, потомки; продолжение — в обратном порядке.
    #[test]
    fn foreground_job_takes_its_shell_along_shell_first() {
        let plan = plan(
            &matched(&[(200, MatchBasis::Rule), (201, MatchBasis::Descendant)]),
            &[shell(), claude(), child()],
        );
        assert_eq!(plan.stop_order, vec![100, 200, 201]);
        assert_eq!(plan.resume_order(), vec![201, 200, 100]);
        assert_eq!(plan.shells, vec![100]);
        assert_eq!(
            plan.shell_targets.get(&100).map(String::as_str),
            Some("claude"),
            "запись журнала обязана назвать цель, ради терминала которой шелл встал"
        );
        assert!(plan.backgrounded.is_empty());
    }

    /// Фоновое задание (`claude &`): группа не передняя — шелл не трогаем, цель помечена.
    #[test]
    fn background_job_leaves_the_shell_alone_and_is_marked() {
        let background = snapshot(200, 100, "/c", 200, 100);
        let plan = plan(&matched(&[(200, MatchBasis::Rule)]), &[shell(), background]);
        assert_eq!(plan.stop_order, vec![200]);
        assert!(plan.shells.is_empty());
        assert_eq!(plan.backgrounded, vec![200]);
    }

    /// GUI-приложение без tty — обычное дерево, родитель первым, без пометок.
    #[test]
    fn gui_app_without_tty_is_ordered_parent_first() {
        let app = detached(300, 1, "/usr/bin/chatgpt");
        let helper = detached(301, 300, "/usr/lib/chatgpt/helper");
        let grandchild = detached(302, 301, "/usr/bin/node");
        let plan = plan(
            &matched(&[
                (301, MatchBasis::Rule),
                (300, MatchBasis::Rule),
                (302, MatchBasis::Descendant),
            ]),
            &[grandchild, helper, app],
        );
        assert_eq!(plan.stop_order, vec![300, 301, 302]);
        assert!(plan.backgrounded.is_empty());
        assert!(plan.shells.is_empty());
    }

    /// Уже стоящий (Ctrl-Z) не трогаем ни при паузе, ни при возобновлении.
    #[test]
    fn already_stopped_processes_are_skipped() {
        let stopped = ProcessSnapshot {
            is_stopped: true,
            ..child()
        };
        let plan = plan(
            &matched(&[(200, MatchBasis::Rule), (201, MatchBasis::Descendant)]),
            &[shell(), claude(), stopped],
        );
        assert_eq!(plan.stop_order, vec![100, 200]);
        assert_eq!(plan.skipped, vec![201]);
    }

    /// Шелл, который сам является целью, вторым разом в план не попадает. Он же —
    /// регресс-тест на то, что интерактивный шелл, ждущий СВОЙ передний план (его группа —
    /// не передняя группа tty, потому что передняя группа принадлежит ребёнку),
    /// не помечается как «фоновое задание»: `backgrounded` описывает цели, вернуть
    /// которым терминал после SIGCONT нельзя, а тут терминал и так остаётся у шелла.
    #[test]
    fn shell_that_is_itself_matched_is_not_added_twice() {
        let plan = plan(
            &matched(&[
                (100, MatchBasis::Rule),
                (200, MatchBasis::Descendant),
                (201, MatchBasis::Descendant),
            ]),
            &[shell(), claude(), child()],
        );
        assert_eq!(plan.stop_order, vec![100, 200, 201]);
        assert_eq!(plan.resume_order(), vec![201, 200, 100]);
        assert!(plan.shells.is_empty());
        assert!(plan.backgrounded.is_empty());
    }

    /// Лидер группы — не сама цель, а обёртка: шелл ищется от лидера.
    #[test]
    fn shell_is_found_from_the_group_leader_not_the_target() {
        let wrapper = snapshot(200, 100, "/bin/sh", 200, 200);
        let target = snapshot(210, 200, "/c", 200, 200);
        let plan = plan(
            &matched(&[(210, MatchBasis::Rule)]),
            &[shell(), wrapper, target],
        );
        assert_eq!(plan.stop_order, vec![100, 210]);
        assert_eq!(plan.shells, vec![100]);
    }

    #[test]
    fn ancestors_walk_to_the_root() {
        let tree = ProcessTree::new(&[shell(), claude(), child()]);
        assert_eq!(tree.ancestors(201), vec![200, 100, 1]);
    }

    /// Шелл, найденный через лидера группы, уже стоял (Ctrl-Z) до нас — это не наша пауза,
    /// и трогать его нельзя ни при остановке, ни при возобновлении: SIGCONT пользовательскому
    /// Ctrl-Z запрещён так же, как SIGSTOP.
    #[test]
    fn shell_found_via_group_leader_that_is_already_stopped_is_untouched() {
        let stopped_shell = ProcessSnapshot {
            is_stopped: true,
            ..shell()
        };
        let plan = plan(
            &matched(&[(200, MatchBasis::Rule), (201, MatchBasis::Descendant)]),
            &[stopped_shell, claude(), child()],
        );
        assert_eq!(plan.stop_order, vec![200, 201]);
        assert_eq!(plan.resume_order(), vec![201, 200]);
        assert!(plan.shells.is_empty());
    }

    /// Двое потомков на одной глубине: сортировка внутри группы одной глубины — по pid,
    /// а не по порядку появления в `matched`.
    #[test]
    fn siblings_at_equal_depth_are_ordered_by_pid() {
        let parent = detached(400, 1, "/a");
        let child_b = detached(402, 400, "/b");
        let child_a = detached(401, 400, "/a2");
        let plan = plan(
            &matched(&[
                (400, MatchBasis::Rule),
                (402, MatchBasis::Descendant),
                (401, MatchBasis::Descendant),
            ]),
            &[child_b, child_a, parent],
        );
        assert_eq!(plan.stop_order, vec![400, 401, 402]);
        assert_eq!(plan.resume_order(), vec![402, 401, 400]);
    }

    /// Лидер группы цели уже вышел и в снимке отсутствует — root намеренно считается
    /// собственным лидером, а поиск шелла-родителя идёт как обычно через `parent_pid`.
    #[test]
    fn missing_group_leader_falls_back_to_root_as_its_own_leader() {
        let target = snapshot(210, 100, "/c", 200, 200);
        let plan = plan(&matched(&[(210, MatchBasis::Rule)]), &[shell(), target]);
        assert_eq!(plan.stop_order, vec![100, 210]);
        assert_eq!(plan.shells, vec![100]);
    }

    // Передний план принадлежит поддереву цели, а не только её группе.

    /// Цель отдала терминал своему ребёнку, поставившему себя в отдельную группу
    /// (`setpgid` + `tcsetpgrp`): группа цели передней не является, но цель по-прежнему
    /// переднее задание шелла. Шелл обязан войти в план первым — иначе zsh узнаёт
    /// о SIGSTOP цели, забирает терминал и цель становится фоновым заданием насовсем.
    #[test]
    fn foreground_group_owned_by_a_child_still_takes_the_shell_along() {
        let shell_waiting = snapshot(100, 1, "/bin/zsh", 100, 300);
        let target = snapshot(200, 100, "/bin/sh", 200, 300);
        let grabber = snapshot(300, 200, "/usr/bin/perl", 300, 300);
        let plan = plan(
            &matched(&[(200, MatchBasis::Rule), (300, MatchBasis::Descendant)]),
            &[shell_waiting, target, grabber],
        );
        assert_eq!(
            plan.stop_order,
            vec![100, 200, 300],
            "порядок — часть контракта: шелл раньше своей цели, цель раньше потомков"
        );
        assert_eq!(plan.resume_order(), vec![300, 200, 100]);
        assert_eq!(plan.shells, vec![100]);
        assert!(
            plan.backgrounded.is_empty(),
            "терминал держит потомок цели — цель в переднем плане, а не в фоне"
        );
    }

    /// То же, но группу держит внук: членство в поддереве, а не глубина ровно один.
    #[test]
    fn foreground_group_owned_by_a_grandchild_still_takes_the_shell_along() {
        let shell_waiting = snapshot(100, 1, "/bin/zsh", 100, 400);
        let target = snapshot(200, 100, "/bin/sh", 200, 400);
        let middle = snapshot(300, 200, "/usr/bin/node", 200, 400);
        let grabber = snapshot(400, 300, "/usr/bin/perl", 400, 400);
        let plan = plan(
            &matched(&[
                (200, MatchBasis::Rule),
                (300, MatchBasis::Descendant),
                (400, MatchBasis::Descendant),
            ]),
            &[shell_waiting, target, middle, grabber],
        );
        assert_eq!(plan.stop_order, vec![100, 200, 300, 400]);
        assert_eq!(plan.resume_order(), vec![400, 300, 200, 100]);
        assert_eq!(plan.shells, vec![100]);
        assert!(plan.backgrounded.is_empty());
    }

    /// Передняя группа принадлежит чужому заданию того же шелла: терминал у соседа,
    /// цель действительно в фоне. Шелл не трогаем, подсказку про `fg` цель получает.
    #[test]
    fn foreground_group_owned_by_an_unrelated_process_is_genuinely_backgrounded() {
        let shell_waiting = snapshot(100, 1, "/bin/zsh", 100, 500);
        let target = snapshot(200, 100, "/c", 200, 500);
        let sibling = snapshot(500, 100, "/usr/bin/vim", 500, 500);
        let plan = plan(
            &matched(&[(200, MatchBasis::Rule)]),
            &[shell_waiting, target, sibling],
        );
        assert_eq!(plan.stop_order, vec![200]);
        assert!(plan.shells.is_empty());
        assert_eq!(plan.backgrounded, vec![200]);
    }

    /// Цель — сам интерактивный шелл, ждущий своего переднего задания. Он в переднем плане
    /// (терминал у его потомка) и в план входит сам, а его родитель — `login -fp user`
    /// из настоящего дерева эмулятора терминала — job control не ведёт и терминал
    /// у остановленной цели не отбирает: SIGSTOP ему — сигнал не по делу.
    ///
    /// Форма родителя здесь честная и самая неудобная: тот же управляющий терминал,
    /// что у шелла, своя группа процессов. Ни условие «на том же терминале»,
    /// ни лидерство сессии его не отсекают — отсекает только то, что `login`
    /// шеллом не является.
    #[test]
    fn interactive_shell_target_does_not_drag_in_its_own_parent() {
        let login = snapshot(50, 1, "/usr/bin/login", 50, 200);
        let plan = plan(
            &matched(&[
                (100, MatchBasis::Rule),
                (200, MatchBasis::Descendant),
                (201, MatchBasis::Descendant),
            ]),
            &[login, shell(), claude(), child()],
        );
        assert_eq!(plan.stop_order, vec![100, 200, 201]);
        assert_eq!(plan.resume_order(), vec![201, 200, 100]);
        assert!(
            plan.shells.is_empty(),
            "`login` шеллом цели не является: терминал он не отберёт"
        );
        assert!(plan.backgrounded.is_empty());
    }

    /// Обратная сторона того же условия: вложенный шелл на том же терминале — настоящий
    /// шелл цели, и он обязан войти в план первым. Форма та же, что у `login`
    /// (родитель в своей группе на том же tty), и разводит их только то, что здесь
    /// родитель ведёт job control: узнав о SIGSTOP, он и заберёт терминал себе.
    #[test]
    fn nested_shell_on_the_same_terminal_is_taken_along() {
        let outer = snapshot(100, 1, "/bin/zsh", 100, 300);
        let inner = snapshot(200, 100, "/bin/bash", 200, 300);
        let job = snapshot(300, 200, "/usr/bin/vim", 300, 300);
        let plan = plan(
            &matched(&[(200, MatchBasis::Rule), (300, MatchBasis::Descendant)]),
            &[outer, inner, job],
        );
        assert_eq!(plan.stop_order, vec![100, 200, 300]);
        assert_eq!(plan.resume_order(), vec![300, 200, 100]);
        assert_eq!(plan.shells, vec![100]);
        assert!(plan.backgrounded.is_empty());
    }

    /// Две цели на одном терминале под одним шеллом: шелл входит в план один раз
    /// и имя получает от первой.
    #[test]
    fn two_targets_sharing_one_shell_add_the_shell_once() {
        let first = snapshot(200, 100, "/home/me/.local/bin/claude", 200, 200);
        let second = snapshot(210, 100, "/home/me/.local/bin/codex", 200, 200);
        let plan = plan(
            &matched(&[(200, MatchBasis::Rule), (210, MatchBasis::Rule)]),
            &[shell(), first, second],
        );
        assert_eq!(plan.shells, vec![100]);
        assert_eq!(plan.stop_order, vec![100, 200, 210]);
        assert_eq!(plan.shell_targets.len(), 1);
    }

    /// Пустой план ничего не требует от границы сигналов.
    #[test]
    fn nothing_matched_is_an_empty_plan() {
        let plan = plan(&[], &[shell(), claude()]);
        assert!(plan.is_empty());
        assert!(plan.resume_order().is_empty());
    }
}
