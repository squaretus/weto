import XCTest
@testable import WetoCore

final class KillEventTests: XCTestCase {

    private let episode = UUID(uuidString: "0FE1B3A2-0000-4000-8000-000000000001")!

    private func event(
        target: String = "claude",
        pid: Int32 = 100,
        reason: String = "Адрес 1.2.3.4 в чёрном списке"
    ) -> KillEvent {
        KillEvent(
            episodeID: episode,
            date: Date(timeIntervalSince1970: 1),
            targetName: target,
            pid: pid,
            parentPID: 1,
            executablePath: "/Users/square/.local/bin/claude",
            isDescendant: false,
            kind: .terminated,
            reasonText: reason,
            ip: nil,
            country: nil,
            confirmedCountry: nil,
            confirmSource: nil
        )
    }

    // MARK: - Запись описывает один процесс

    /// Раньше запись описывала проход охраны: «claude» и тридцать четыре pid одной
    /// строкой. По такой записи нельзя ответить на главный вопрос — что именно
    /// завершилось, — а ради этого журнал и ведётся.
    func test_event_describes_a_single_process() {
        let one = event(pid: 100)

        XCTAssertEqual(one.targetName, "claude")
        XCTAssertEqual(one.pid, 100)
        XCTAssertEqual(one.parentPID, 1)
        XCTAssertEqual(one.executablePath, "/Users/square/.local/bin/claude")
    }

    /// Проход охраны склеивается эпизодом: тридцать четыре записи об одном падении
    /// VPN — это одно событие, и в выгрузке это должно быть видно.
    func test_events_of_one_pass_share_the_episode() {
        let events = [event(pid: 100), event(pid: 101)]

        XCTAssertEqual(Set(events.map(\.episodeID)).count, 1)
        XCTAssertNotEqual(events[0].id, events[1].id, "у записей свои идентификаторы")
    }

    // MARK: - Чтение прежнего журнала

    /// Журнал прежнего формата не выбрасывается: он и есть история, ради которой
    /// ёмкость поднимали. Одна старая запись про N процессов разворачивается
    /// в N записей одного эпизода.
    func test_legacy_grouped_record_expands_into_one_event_per_process() throws {
        let legacy = """
        [{
            "id": "822543BC-4FFD-4659-A783-C0673BBCB59B",
            "date": 809519566.380361,
            "killedPIDs": [92594, 92261, 26200],
            "targetNames": ["claude"],
            "kind": "terminated",
            "reasonText": "Подключение ещё не проверено"
        }]
        """

        let events = try KillEvent.decodeLog(Data(legacy.utf8))

        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.map(\.pid), [92594, 92261, 26200])
        XCTAssertEqual(Set(events.map(\.targetName)), ["claude"])
        XCTAssertEqual(Set(events.map(\.episodeID)).count, 1, "старая запись — один эпизод")
        XCTAssertEqual(events.first?.reasonText, "Подключение ещё не проверено")
    }

    /// У прежней записи целей могло быть несколько, а вот кто из них какой pid —
    /// не сохранялось. Выдумывать привязку нельзя: цель называется только там,
    /// где она была одна.
    func test_legacy_record_with_several_targets_does_not_invent_the_owner() throws {
        let legacy = """
        [{
            "id": "B82809AD-67A2-44AE-8585-204818459BE1",
            "date": 809443502.61667,
            "killedPIDs": [17232, 17343],
            "targetNames": ["claude", "ChatGPT"],
            "kind": "terminated",
            "reasonText": "Не удалось определить внешний адрес: таймаут запроса"
        }]
        """

        let events = try KillEvent.decodeLog(Data(legacy.utf8))

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(Set(events.map(\.targetName)), ["claude, ChatGPT"])
    }

    func test_new_format_reads_back_unchanged() throws {
        let events = [event(pid: 100), event(pid: 101)]
        let data = try JSONEncoder().encode(events)

        XCTAssertEqual(try KillEvent.decodeLog(data), events)
    }

    /// Пустой и битый журнал — не данные пользователя, а история: охране они
    /// мешать не должны.
    func test_broken_log_reads_as_empty() {
        XCTAssertEqual(try? KillEvent.decodeLog(Data("не json".utf8)), nil)
    }
}
