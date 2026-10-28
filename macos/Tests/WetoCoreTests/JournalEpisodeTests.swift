import XCTest
@testable import WetoCore

final class JournalEpisodeTests: XCTestCase {

    private let first = UUID(uuidString: "0FE1B3A2-0000-4000-8000-000000000001")!
    private let second = UUID(uuidString: "0FE1B3A2-0000-4000-8000-000000000002")!

    private func event(
        _ episode: UUID,
        target: String = "Claude",
        pid: Int32,
        at seconds: TimeInterval = 0,
        matchedBy: MatchBasis = .rule,
        resolution: String? = nil,
        ip: String? = nil
    ) -> KillEvent {
        KillEvent(
            episodeID: episode,
            date: Date(timeIntervalSince1970: seconds),
            targetName: target,
            pid: pid,
            parentPID: 1,
            executablePath: "/Users/square/.local/bin/claude",
            matchedBy: matchedBy,
            kind: .paused,
            reasonText: "Не удалось определить внешний адрес: таймаут запроса",
            resolutionText: resolution,
            ip: ip,
            country: ip == nil ? nil : "KZ",
            confirmedCountry: ip == nil ? nil : "KZ",
            confirmSource: ip == nil ? nil : "geojs"
        )
    }

    /// Одно падение VPN на дереве claude — десятки записей, по одной на процесс.
    /// В окне это одна строка: pid там не говорит ничего, а шесть одинаковых строк
    /// подряд прятали всю остальную историю.
    func test_records_of_one_pass_make_one_line() {
        let log = (0..<6).map { event(first, pid: 56710 + $0) } + [event(second, pid: 4000)]

        let episodes = JournalEpisode.group(log)

        XCTAssertEqual(episodes.map(\.id), [first, second])
        XCTAssertEqual(episodes.map(\.processCount), [6, 1])
    }

    /// Процесс, вставший под уже идущей паузой, пишется тем же эпизодом позже —
    /// поверх записей других эпизодов. Строка от этого не раздваивается и стоит
    /// там, где эпизод последний раз что-то записал.
    func test_a_late_record_joins_its_episode_instead_of_opening_a_line() {
        let log = [event(first, pid: 3, at: 30), event(second, pid: 2, at: 20), event(first, pid: 1, at: 10)]

        let episodes = JournalEpisode.group(log)

        XCTAssertEqual(episodes.map(\.id), [first, second])
        XCTAssertEqual(episodes.first?.processCount, 2)
        XCTAssertEqual(episodes.first?.date, Date(timeIntervalSince1970: 10),
                       "время эпизода — когда цели встали, а не когда встал последний")
    }

    /// Заголовок — цели, а не процессы: каждая один раз, в порядке, в каком
    /// эпизод их задел.
    func test_title_names_each_target_once() {
        let log = [
            event(first, target: "codex", pid: 3),
            event(first, target: "Claude", pid: 2),
            event(first, target: "Claude", pid: 1),
        ]

        XCTAssertEqual(JournalEpisode.group(log).first?.title, "Claude, codex")

        let nameless = [event(first, target: "", pid: 1)]
        XCTAssertEqual(JournalEpisode.group(nameless).first?.title, "неизвестная цель")
    }

    /// У шелла свой исход — «продолжен: цель завершена …», — а строка рассказывает
    /// про цели. Исход шелла показывается только тогда, когда других нет.
    func test_outcome_is_the_targets_one_and_said_once() {
        let log = [
            event(first, pid: 3, matchedBy: .shell, resolution: "продолжен: цель завершена по потолку"),
            event(first, pid: 2, matchedBy: .descendant, resolution: "завершено по потолку"),
            event(first, pid: 1, resolution: "завершено по потолку"),
        ]
        XCTAssertEqual(JournalEpisode.group(log).first?.resolutionLine, "Итог: завершено по потолку")

        let released = [
            event(first, target: "codex", pid: 2, resolution: "продолжен: цель снята с охраны"),
            event(first, pid: 1, resolution: "завершено по потолку"),
        ]
        XCTAssertEqual(JournalEpisode.group(released).first?.resolutionLine,
                       "Итог: завершено по потолку; продолжен: цель снята с охраны")

        let onlyShell = [event(first, pid: 1, matchedBy: .shell, resolution: "продолжен")]
        XCTAssertEqual(JournalEpisode.group(onlyShell).first?.resolutionLine, "Итог: продолжен")

        XCTAssertNil(JournalEpisode.group([event(first, pid: 1)]).first?.resolutionLine,
                     "без исхода строки нет вовсе")
    }

    /// Строка показаний — дословно та же, что на Linux: время первым, адрес всегда,
    /// затем страны и число процессов, если их больше одного. Ни pid, ни «потомок N».
    func test_diagnostics_name_the_exit_and_how_many_processes_stood() {
        let one = JournalEpisode.group([event(first, pid: 1)])[0]
        XCTAssertEqual(one.diagnosticsText(timestamp: "t"), "t · IP: неизвестен")

        let many = JournalEpisode.group([
            event(first, pid: 2, matchedBy: .descendant, ip: "212.19.134.212"),
            event(first, pid: 1, ip: "212.19.134.212"),
        ])[0]
        XCTAssertEqual(many.diagnosticsText(timestamp: "28.10.2026 08:29:00"),
                       "28.10.2026 08:29:00 · IP: 212.19.134.212 · ipinfo: KZ · geojs: KZ · процессов: 2")
    }

    /// Пауза по молчанию сервисов несёт адрес и страны прошлого вердикта — других нет.
    /// Строка «IP … · ipinfo: KZ · geojs: KZ» под причиной «таймаут запроса» читалась
    /// как «всё ответило KZ, а цели почему-то встали». Прошлый вердикт назван прошлым.
    func test_an_established_verdict_is_not_passed_off_as_this_probes_answer() {
        let silent = KillEvent(
            episodeID: first, date: Date(timeIntervalSince1970: 0), targetName: "Claude", pid: 1,
            kind: .paused, reasonText: "Не удалось определить внешний адрес: таймаут запроса (соединение)",
            ip: "176.12.76.15", country: "KZ", confirmedCountry: "KZ", confirmSource: "freeipapi",
            diagnostics: KillDiagnostics(verdictOrigin: .established)
        )

        XCTAssertEqual(JournalEpisode.group([silent])[0].diagnosticsText(timestamp: "t"),
                       "t · последний подтверждённый выход: 176.12.76.15, KZ")
    }

    func test_summary_is_the_kind_and_the_reason() {
        XCTAssertEqual(JournalEpisode.group([event(first, pid: 1)]).first?.summaryText,
                       "на паузе — не удалось определить внешний адрес: таймаут запроса")
    }
}
