import XCTest
@testable import WetoCore

final class PausePlannerTests: XCTestCase {

    // zsh (pid 100, своя группа 100, tty в переднем плане у группы 200) → claude (200, лидер группы 200)
    // → node (201, потомок в той же группе).
    private let shell = ProcessSnapshot(pid: 100, parentPID: 1, executablePath: "/bin/zsh",
                                        processGroup: 100, terminalForegroundGroup: 200)
    private let claude = ProcessSnapshot(pid: 200, parentPID: 100, executablePath: "/Users/me/.local/bin/claude",
                                         processGroup: 200, terminalForegroundGroup: 200)
    private let child = ProcessSnapshot(pid: 201, parentPID: 200, executablePath: "/usr/bin/node",
                                        processGroup: 200, terminalForegroundGroup: 200)

    private func matched(_ pids: [(Int32, MatchBasis)]) -> [MatchedProcess] {
        pids.map { MatchedProcess(pid: $0.0, targetName: "claude", matchedBy: $0.1) }
    }

    /// Стоп — шелл, цель, потомки; продолжение — в обратном порядке. Проверено на zsh и bash 3.2.
    func test_foreground_job_takes_its_shell_along_shell_first() {
        let plan = PausePlanner.plan(matched: matched([(200, .rule), (201, .descendant)]),
                                     processes: [shell, claude, child])
        XCTAssertEqual(plan.stopOrder, [100, 200, 201])
        XCTAssertEqual(plan.resumeOrder, [201, 200, 100])
        XCTAssertEqual(plan.shells, [100])
        XCTAssertTrue(plan.backgrounded.isEmpty)
    }

    /// Фоновое задание (`claude &`): группа не передняя — шелл не трогаем, цель помечена.
    func test_background_job_leaves_the_shell_alone_and_is_marked() {
        let backgroundClaude = ProcessSnapshot(pid: 200, parentPID: 100, executablePath: "/c",
                                               processGroup: 200, terminalForegroundGroup: 100)
        let plan = PausePlanner.plan(matched: matched([(200, .rule)]), processes: [shell, backgroundClaude])
        XCTAssertEqual(plan.stopOrder, [200])
        XCTAssertTrue(plan.shells.isEmpty)
        XCTAssertEqual(plan.backgrounded, [200])
    }

    /// GUI-приложение без tty — обычное дерево, родитель первым, без пометок.
    func test_gui_app_without_tty_is_ordered_parent_first() {
        let app = ProcessSnapshot(pid: 300, parentPID: 1, executablePath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT")
        let helper = ProcessSnapshot(pid: 301, parentPID: 300, executablePath: "/Applications/ChatGPT.app/Contents/Frameworks/H")
        let grandchild = ProcessSnapshot(pid: 302, parentPID: 301, executablePath: "/usr/bin/node")
        let plan = PausePlanner.plan(matched: matched([(301, .rule), (300, .rule), (302, .descendant)]),
                                     processes: [grandchild, helper, app])
        XCTAssertEqual(plan.stopOrder, [300, 301, 302])
        XCTAssertTrue(plan.backgrounded.isEmpty)
        XCTAssertTrue(plan.shells.isEmpty)
    }

    /// Уже стоящий (Ctrl-Z) не трогаем ни при паузе, ни при возобновлении.
    func test_already_stopped_processes_are_skipped() {
        let stopped = ProcessSnapshot(pid: 201, parentPID: 200, executablePath: "/usr/bin/node",
                                      processGroup: 200, terminalForegroundGroup: 200, isStopped: true)
        let plan = PausePlanner.plan(matched: matched([(200, .rule), (201, .descendant)]),
                                     processes: [shell, claude, stopped])
        XCTAssertEqual(plan.stopOrder, [100, 200])
        XCTAssertEqual(plan.skipped, [201])
    }

    /// Шелл, который сам является целью, вторым разом в план не попадает. Он же — регресс-тест
    /// на то, что интерактивный шелл, ждущий СВОЙ передний план (его группа — не передняя группа
    /// tty, потому что передняя группа принадлежит ребёнку), не помечается как «фоновое задание»:
    /// `backgrounded` описывает цели, вернуть которым терминал после SIGCONT нельзя, а тут
    /// терминал и так остаётся у шелла.
    func test_shell_that_is_itself_matched_is_not_added_twice() {
        let plan = PausePlanner.plan(matched: matched([(100, .rule), (200, .descendant), (201, .descendant)]),
                                     processes: [shell, claude, child])
        XCTAssertEqual(plan.stopOrder, [100, 200, 201])
        XCTAssertEqual(plan.resumeOrder, [201, 200, 100])
        XCTAssertTrue(plan.shells.isEmpty)
        XCTAssertTrue(plan.backgrounded.isEmpty)
    }

    /// Лидер группы — не сама цель, а обёртка: шелл ищется от лидера.
    func test_shell_is_found_from_the_group_leader_not_the_target() {
        let wrapper = ProcessSnapshot(pid: 200, parentPID: 100, executablePath: "/bin/sh",
                                      processGroup: 200, terminalForegroundGroup: 200)
        let target = ProcessSnapshot(pid: 210, parentPID: 200, executablePath: "/c",
                                     processGroup: 200, terminalForegroundGroup: 200)
        let plan = PausePlanner.plan(matched: matched([(210, .rule)]), processes: [shell, wrapper, target])
        XCTAssertEqual(plan.stopOrder, [100, 210])
        XCTAssertEqual(plan.shells, [100])
    }

    func test_ancestors_walk_to_the_root() {
        let tree = ProcessTree(processes: [shell, claude, child])
        XCTAssertEqual(tree.ancestors(of: 201), [200, 100, 1])
    }

    /// Шелл, найденный через лидера группы, уже стоял (Ctrl-Z) до нас — это не наша пауза,
    /// и трогать его нельзя ни при остановке, ни при возобновлении: SIGCONT пользовательскому
    /// Ctrl-Z запрещён спекой так же, как SIGSTOP.
    func test_shell_found_via_group_leader_that_is_already_stopped_is_untouched() {
        let stoppedShell = ProcessSnapshot(pid: 100, parentPID: 1, executablePath: "/bin/zsh",
                                           processGroup: 100, terminalForegroundGroup: 200, isStopped: true)
        let plan = PausePlanner.plan(matched: matched([(200, .rule), (201, .descendant)]),
                                     processes: [stoppedShell, claude, child])
        XCTAssertEqual(plan.stopOrder, [200, 201])
        XCTAssertEqual(plan.resumeOrder, [201, 200])
        XCTAssertTrue(plan.shells.isEmpty)
    }

    /// Двое потомков на одной глубине: сортировка внутри группы одной глубины — по pid,
    /// а не по порядку появления в `matched`.
    func test_siblings_at_equal_depth_are_ordered_by_pid() {
        let parent = ProcessSnapshot(pid: 400, parentPID: 1, executablePath: "/a")
        let childB = ProcessSnapshot(pid: 402, parentPID: 400, executablePath: "/b")
        let childA = ProcessSnapshot(pid: 401, parentPID: 400, executablePath: "/a2")
        let plan = PausePlanner.plan(matched: matched([(400, .rule), (402, .descendant), (401, .descendant)]),
                                     processes: [childB, childA, parent])
        XCTAssertEqual(plan.stopOrder, [400, 401, 402])
        XCTAssertEqual(plan.resumeOrder, [402, 401, 400])
    }

    /// Лидер группы цели уже вышел и в снимке отсутствует — root намеренно считается собственным
    /// лидером, а поиск шелла-родителя идёт как обычно через `parentPID`.
    func test_missing_group_leader_falls_back_to_root_as_its_own_leader() {
        let target = ProcessSnapshot(pid: 210, parentPID: 100, executablePath: "/c",
                                     processGroup: 200, terminalForegroundGroup: 200)
        let plan = PausePlanner.plan(matched: matched([(210, .rule)]), processes: [shell, target])
        XCTAssertEqual(plan.stopOrder, [100, 210])
        XCTAssertEqual(plan.shells, [100])
    }
}
