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
            matchedBy: .rule,
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

    /// Тексты видов записи общие с Linux дословно: файл выгрузки читают на обеих
    /// платформах, и «на паузе» обязано звучать одинаково.
    func test_kind_texts_are_the_shared_wording() {
        XCTAssertEqual(KillEventKind.terminated.displayText, "завершено")
        XCTAssertEqual(KillEventKind.launchBlocked.displayText, "запуск запрещён")
        XCTAssertEqual(KillEventKind.paused.displayText, "на паузе")
        XCTAssertEqual(KillEventKind.paused.rawValue, "paused", "имя в файле — часть формата")
    }

    // MARK: - matchedBy

    /// Поле означало «совпал только как потомок», а читалось как «имеет родителя».
    func test_matched_by_is_encoded_instead_of_is_descendant() throws {
        let event = KillEvent(
            episodeID: UUID(), date: Date(), targetName: "codex", pid: 7, parentPID: 3,
            executablePath: "/x", matchedBy: .descendant, kind: .terminated,
            reasonText: "r", ip: nil, country: nil
        )
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode([event])) as? [[String: Any]]
        XCTAssertEqual(object?.first?["matchedBy"] as? String, "descendant")
        XCTAssertNil(object?.first?["isDescendant"])
    }

    /// Шелл — третий способ попасть в журнал: под правило он не подходил, а SIGSTOP
    /// получил. Имя в файле — часть общего с Linux формата, текст — общий дословно.
    func test_shell_is_a_match_basis_of_its_own() throws {
        let event = KillEvent(
            episodeID: UUID(), date: Date(), targetName: "claude", pid: 100, parentPID: 1,
            executablePath: "/bin/zsh", matchedBy: .shell, kind: .paused,
            reasonText: "r", ip: nil, country: nil
        )
        let data = try JSONEncoder().encode([event])
        let object = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        XCTAssertEqual(object?.first?["matchedBy"] as? String, "shell")
        XCTAssertEqual(try KillEvent.decodeLog(data).first?.matchedBy, .shell)
        XCTAssertEqual(MatchBasis.shell.detailText(parentPID: 1), "шелл терминала цели")
        XCTAssertEqual(MatchBasis.descendant.detailText(parentPID: 200), "потомок 200")
        XCTAssertNil(MatchBasis.rule.detailText(parentPID: 1))
    }

    func test_legacy_is_descendant_is_read_as_matched_by() throws {
        let legacy = """
        [{"id":"5D2C1F1E-0000-4000-8000-000000000001","episodeID":"5D2C1F1E-0000-4000-8000-000000000002",
          "date":0,"targetName":"claude","pid":5,"parentPID":1,"executablePath":"/c",
          "isDescendant":true,"kind":"terminated","reasonText":"r"}]
        """
        let events = try KillEvent.decodeLog(Data(legacy.utf8))
        XCTAssertEqual(events.first?.matchedBy, .descendant)
    }
}
