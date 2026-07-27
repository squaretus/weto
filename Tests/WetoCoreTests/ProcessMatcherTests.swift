import XCTest
@testable import WetoCore

final class ProcessMatcherTests: XCTestCase {

    private func app(_ path: String, name: String) -> TargetRule {
        TargetRule(entry: name, displayName: name, kind: .appBundle, path: path)
    }

    private func binary(_ path: String, name: String) -> TargetRule {
        TargetRule(entry: name, displayName: name, kind: .binary, path: path)
    }

    private func script(_ path: String, name: String) -> TargetRule {
        TargetRule(entry: name, displayName: name, kind: .script, path: path)
    }

    private let processes: [ProcessSnapshot] = [
        .init(pid: 100, parentPID: 1, executablePath: "/Applications/Target.app/Contents/MacOS/Target"),
        .init(pid: 101, parentPID: 1, executablePath: "/Applications/Target.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"),
        .init(pid: 102, parentPID: 1, executablePath: "/Applications/Other.app/Contents/MacOS/Other"),
        .init(pid: 103, parentPID: 1, executablePath: "/usr/bin/ssh"),
        .init(pid: 104, parentPID: 1, executablePath: "/Applications/TargetExtra.app/Contents/MacOS/TargetExtra"),
    ]

    func test_matches_main_binary_and_nested_helpers() {
        let pids = ProcessMatcher.pids(
            in: processes, rules: [app("/Applications/Target.app", name: "Target")]
        )
        XCTAssertEqual(pids, [100, 101])
    }

    func test_does_not_match_sibling_bundle_with_shared_prefix() {

        let pids = ProcessMatcher.pids(
            in: processes, rules: [app("/Applications/Target.app", name: "Target")]
        )
        XCTAssertFalse(pids.contains(104))
    }

    func test_matches_across_several_targets() {
        let pids = ProcessMatcher.pids(in: processes, rules: [
            app("/Applications/Target.app", name: "Target"),
            app("/Applications/Other.app", name: "Other"),
        ])
        XCTAssertEqual(pids, [100, 101, 102])
    }

    func test_trailing_slash_in_bundle_path_is_tolerated() {
        let pids = ProcessMatcher.pids(
            in: processes, rules: [app("/Applications/Target.app/", name: "Target")]
        )
        XCTAssertEqual(pids, [100, 101])
    }

    func test_empty_rule_list_matches_nothing() {
        XCTAssertTrue(ProcessMatcher.pids(in: processes, rules: []).isEmpty)
    }

    func test_matched_processes_carry_target_name() {
        let matched = ProcessMatcher.matches(
            in: processes, rules: [app("/Applications/Target.app", name: "Target")]
        )
        XCTAssertEqual(matched.map(\.targetName), ["Target", "Target"])
    }

    func test_first_matching_rule_wins_for_naming() {
        let matched = ProcessMatcher.matches(in: processes, rules: [
            app("/Applications/Target.app", name: "Первая"),
            app("/Applications/Target.app", name: "Вторая"),
        ])
        XCTAssertEqual(matched.first?.targetName, "Первая")
    }

    func test_binary_is_matched_by_exact_resolved_path() {

        let tree: [ProcessSnapshot] = [
            .init(pid: 700, parentPID: 1, executablePath: "/usr/bin/pico"),
            .init(pid: 701, parentPID: 1, executablePath: "/usr/bin/vim"),
        ]
        let matched = ProcessMatcher.matches(
            in: tree, rules: [binary("/usr/bin/pico", name: "nano")]
        )
        XCTAssertEqual(matched.map(\.pid), [700])
        XCTAssertEqual(matched.first?.targetName, "nano")
    }

    func test_script_is_matched_by_command_line_not_by_interpreter() {

        let tree: [ProcessSnapshot] = [
            .init(pid: 800, parentPID: 1, executablePath: "/opt/homebrew/bin/node",
                  arguments: "node /opt/homebrew/lib/qwen/cli.js chat"),
            .init(pid: 801, parentPID: 1, executablePath: "/opt/homebrew/bin/node",
                  arguments: "node /Users/me/other/server.js"),
        ]
        let pids = ProcessMatcher.pids(
            in: tree, rules: [script("/opt/homebrew/lib/qwen/cli.js", name: "qwen")]
        )
        XCTAssertEqual(pids, [800])
    }

    func test_script_rule_ignores_processes_without_arguments() {
        let tree: [ProcessSnapshot] = [
            .init(pid: 800, parentPID: 1, executablePath: "/opt/homebrew/bin/node", arguments: nil)
        ]
        XCTAssertTrue(ProcessMatcher.pids(
            in: tree, rules: [script("/opt/homebrew/lib/qwen/cli.js", name: "qwen")]
        ).isEmpty)
    }

    func test_children_of_a_matched_process_are_included_with_parent_name() {
        let tree: [ProcessSnapshot] = [
            .init(pid: 100, parentPID: 1, executablePath: "/Applications/Target.app/Contents/MacOS/Target"),
            .init(pid: 200, parentPID: 100, executablePath: "/usr/bin/curl"),
            .init(pid: 300, parentPID: 1, executablePath: "/usr/bin/curl"),
        ]
        let matched = ProcessMatcher.matches(
            in: tree, rules: [app("/Applications/Target.app", name: "Target")]
        )
        XCTAssertEqual(matched.map(\.pid), [100, 200], "чужой curl с pid 300 не трогаем")
        XCTAssertEqual(matched.map(\.targetName), ["Target", "Target"])
    }

    func test_grandchildren_are_included() {
        let tree: [ProcessSnapshot] = [
            .init(pid: 100, parentPID: 1, executablePath: "/usr/bin/pico"),
            .init(pid: 200, parentPID: 100, executablePath: "/bin/sh"),
            .init(pid: 300, parentPID: 200, executablePath: "/usr/bin/curl"),
        ]
        let pids = ProcessMatcher.pids(in: tree, rules: [binary("/usr/bin/pico", name: "nano")])
        XCTAssertEqual(Set(pids), [100, 200, 300])
    }

    func test_cycle_in_process_tree_does_not_hang() {

        let tree: [ProcessSnapshot] = [
            .init(pid: 100, parentPID: 200, executablePath: "/usr/bin/pico"),
            .init(pid: 200, parentPID: 100, executablePath: "/bin/sh"),
        ]
        let pids = ProcessMatcher.pids(in: tree, rules: [binary("/usr/bin/pico", name: "nano")])
        XCTAssertEqual(Set(pids), [100, 200])
    }

    func test_zero_parent_pid_does_not_create_a_phantom_root() {

        let tree: [ProcessSnapshot] = [
            .init(pid: 100, parentPID: 0, executablePath: "/usr/bin/pico"),
            .init(pid: 200, parentPID: 0, executablePath: "/usr/bin/vim"),
        ]
        let pids = ProcessMatcher.pids(in: tree, rules: [binary("/usr/bin/pico", name: "nano")])
        XCTAssertEqual(pids, [100])
    }

    func test_running_targets_report_one_row_per_target_with_process_count() {

        let tree: [ProcessSnapshot] = [
            .init(pid: 100, parentPID: 1, executablePath: "/Applications/Target.app/Contents/MacOS/Target"),
            .init(pid: 200, parentPID: 100, executablePath: "/usr/bin/curl"),
            .init(pid: 300, parentPID: 200, executablePath: "/usr/bin/grep"),
            .init(pid: 400, parentPID: 1, executablePath: "/usr/bin/pico"),
        ]

        let running = ProcessMatcher.runningTargets(
            in: tree,
            rules: [
                app("/Applications/Target.app", name: "Target"),
                binary("/usr/bin/pico", name: "nano"),
            ]
        )

        XCTAssertEqual(running.map(\.displayName), ["Target", "nano"])
        XCTAssertEqual(running.map(\.pid), [100, 400])
        XCTAssertEqual(
            running.map(\.processCount), [3, 1],
            "у приложения три процесса вместе с потомками; у nano — один"
        )
        XCTAssertEqual(running.map(\.extraProcessCount), [2, 0])
    }

    func test_target_with_several_root_processes_collapses_into_one_row() {

        let tree: [ProcessSnapshot] = [
            .init(pid: 100, parentPID: 1, executablePath: "/Applications/Target.app/Contents/MacOS/Target"),
            .init(pid: 200, parentPID: 1, executablePath: "/Applications/Target.app/Contents/MacOS/Helper (GPU)"),
            .init(pid: 300, parentPID: 1, executablePath: "/Applications/Target.app/Contents/MacOS/Helper (Renderer)"),
        ]

        let running = ProcessMatcher.runningTargets(
            in: tree, rules: [app("/Applications/Target.app", name: "Target")]
        )

        XCTAssertEqual(
            running.count, 1,
            "хелперы, запущенные launchd, — та же цель, а не три строки виджета"
        )
        XCTAssertEqual(running.first?.processCount, 3)
        XCTAssertEqual(running.first?.pid, 100, "представителем становится младший pid")
    }

    func test_running_targets_count_matching_children_once() {

        let tree: [ProcessSnapshot] = [
            .init(pid: 100, parentPID: 1, executablePath: "/Applications/Target.app/Contents/MacOS/Target"),
            .init(pid: 200, parentPID: 100, executablePath: "/Applications/Target.app/Contents/MacOS/Helper"),
        ]

        let running = ProcessMatcher.runningTargets(
            in: tree, rules: [app("/Applications/Target.app", name: "Target")]
        )

        XCTAssertEqual(running.count, 1)
        XCTAssertEqual(running.first?.processCount, 2)
    }

    func test_running_targets_are_empty_without_matching_processes() {
        XCTAssertTrue(
            ProcessMatcher.runningTargets(
                in: [.init(pid: 100, parentPID: 1, executablePath: "/usr/bin/vim")],
                rules: [binary("/usr/bin/pico", name: "nano")]
            ).isEmpty
        )
    }

    func test_running_targets_survive_a_cycle_in_the_tree() {

        let tree: [ProcessSnapshot] = [
            .init(pid: 100, parentPID: 200, executablePath: "/usr/bin/pico"),
            .init(pid: 200, parentPID: 100, executablePath: "/bin/sh"),
        ]

        let running = ProcessMatcher.runningTargets(
            in: tree, rules: [binary("/usr/bin/pico", name: "nano")]
        )
        XCTAssertEqual(running.map(\.pid), [100])
        XCTAssertEqual(running.first?.processCount, 2, "цикл обходится один раз и не зацикливается")
    }
}
