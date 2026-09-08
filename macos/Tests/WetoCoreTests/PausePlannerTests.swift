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

    /// Шелл, который сам является целью, вторым разом в план не попадает.
    func test_shell_that_is_itself_matched_is_not_added_twice() {
        let plan = PausePlanner.plan(matched: matched([(100, .rule), (200, .descendant), (201, .descendant)]),
                                     processes: [shell, claude, child])
        XCTAssertEqual(plan.stopOrder, [100, 200, 201])
        XCTAssertTrue(plan.shells.isEmpty)
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
}
