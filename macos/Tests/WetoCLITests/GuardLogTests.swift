import XCTest
@testable import WetoCLI
import WetoCore

/// Лог охраны: одна строка на событие — имена, pid, причина; без дубля
/// от уведомителя, у которого pid нет.
final class GuardLogTests: XCTestCase {

    private func event(_ name: String, _ pid: Int32, episode: UUID, kind: KillEventKind = .terminated,
                       resolution: String? = nil) -> KillEvent {
        KillEvent(episodeID: episode, date: Date(), targetName: name, pid: pid, kind: kind,
                  reasonText: "VPN-туннель wg0 не поднят", resolutionText: resolution, ip: nil, country: nil)
    }

    func test_one_line_per_episode_with_names_and_pids() {
        let kill = UUID()
        let pause = UUID()
        let lines = GuardRunner.journalLogLines(
            fresh: [
                event("claude", 4120, episode: kill), event("claude", 4133, episode: kill),
                event("codex", 4200, episode: kill),
                event("qwen", 4300, episode: pause, kind: .paused),
            ],
            resolved: [
                event("qwen", 4300, episode: pause, kind: .paused, resolution: "возобновлено проверкой"),
            ]
        )
        XCTAssertEqual(lines, [
            "завершены: claude ×2, codex (pid 4120, 4133, 4200) — VPN-туннель wg0 не поднят",
            "на паузе: qwen (pid 4300) — VPN-туннель wg0 не поднят",
            "исход паузы: возобновлено проверкой (pid 4300)",
        ])
    }

    /// Завершение в лог пишет журнал; уведомитель о нём молчит, иначе событие легло бы дважды.
    func test_the_notifier_does_not_duplicate_terminations() {
        var written: [String] = []
        let notifier = LogNotifier(log: GuardLog(write: { written.append($0) }))

        notifier.notifyTerminated(reasonText: "claude: VPN-туннель wg0 не поднят", killedCount: 1)
        XCTAssertTrue(written.isEmpty)

        notifier.notifyBackgrounded(targetName: "claude")
        XCTAssertEqual(written.count, 1)
        XCTAssertTrue(written[0].hasSuffix(" claude: процесс вернулся в фон. Откройте терминал и введите fg"))
    }
}
