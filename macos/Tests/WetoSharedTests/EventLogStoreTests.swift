import XCTest
@testable import WetoShared
import WetoCore

@MainActor
final class EventLogStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var directory: URL!

    override func setUp() async throws {
        suiteName = "com.weto.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("weto-journal-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    private func file() -> JournalFile {
        JournalFile(directory: directory)!
    }

    private func store() -> EventLogStore {
        EventLogStore(storage: file())
    }

    private func event(
        _ reason: String,
        pid: Int32 = 42,
        episodeID: UUID = UUID(),
        target: String = "TextEdit"
    ) -> KillEvent {
        KillEvent(
            episodeID: episodeID,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            targetName: target,
            pid: pid,
            kind: .terminated,
            reasonText: reason,
            ip: "203.0.113.28",
            country: "KZ"
        )
    }

    func test_new_store_is_empty() {
        XCTAssertTrue(store().events.isEmpty)
    }

    func test_recorded_pass_appears_first() {
        let store = store()
        store.record([event("первое")])
        store.record([event("второе")])
        XCTAssertEqual(store.events.map(\.reasonText), ["второе", "первое"])
    }

    /// Проход охраны пишется целиком: завершили четыре процесса — четыре записи,
    /// а не одна строка с четырьмя pid внутри.
    func test_pass_is_written_as_a_record_per_process() {
        let store = store()
        let episode = UUID()

        store.record([
            event("причина", pid: 100, episodeID: episode, target: "claude"),
            event("причина", pid: 101, episodeID: episode, target: "claude"),
            event("причина", pid: 200, episodeID: episode, target: "codex"),
        ])

        XCTAssertEqual(store.events.count, 3)
        XCTAssertEqual(store.events.map(\.pid), [100, 101, 200])
        XCTAssertEqual(Set(store.events.map(\.episodeID)), [episode])
    }

    func test_events_survive_a_new_store_over_the_same_file() {
        store().record([event("сохранённое")])
        XCTAssertEqual(store().events.map(\.reasonText), ["сохранённое"])
    }

    /// Журнал переехал из plist настроек в файл: запись теперь на процесс,
    /// ёмкость сто, и в записи едет диагностика. История пользователя при этом
    /// не выбрасывается, а прежний ключ из настроек убирается — иначе он остаётся
    /// мёртвым грузом навсегда.
    func test_journal_moves_out_of_the_settings_plist_keeping_history() throws {
        let legacy = """
        [{
            "id": "822543BC-4FFD-4659-A783-C0673BBCB59B",
            "date": 809519566.380361,
            "killedPIDs": [92594, 92261],
            "targetNames": ["claude"],
            "kind": "terminated",
            "reasonText": "Подключение ещё не проверено"
        }]
        """
        defaults.set(Data(legacy.utf8), forKey: "eventLog")

        let migrated = EventLogStore(storage: file(), migratingFrom: defaults)

        XCTAssertEqual(migrated.events.count, 2, "старая запись развернулась по процессам")
        XCTAssertNil(defaults.data(forKey: "eventLog"), "ключ из настроек убран")
        XCTAssertEqual(store().events.count, 2, "и лежит уже в файле")
    }

    /// Перенос — разовый. Журнал, уже живущий файлом, настройки не переписывают:
    /// иначе пустой файл после «очистить журнал» воскрешал бы старую историю.
    func test_migration_does_not_overwrite_an_existing_file_journal() {
        defaults.set(Data("[]".utf8), forKey: "eventLog")
        let existing = store()
        existing.record([event("своё")])

        let reopened = EventLogStore(storage: file(), migratingFrom: defaults)

        XCTAssertEqual(reopened.events.map(\.reasonText), ["своё"])
    }

    func test_ring_buffer_drops_oldest_beyond_capacity() {
        let store = store()
        for index in 0..<(Constants.eventLogCapacity + 10) {
            store.record([event("событие \(index)")])
        }
        XCTAssertEqual(store.events.count, Constants.eventLogCapacity)
        XCTAssertEqual(store.events.first?.reasonText, "событие \(Constants.eventLogCapacity + 9)")
        XCTAssertEqual(store.events.last?.reasonText, "событие 10")
    }

    /// Сто записей, а не десять: запись теперь на процесс, и одно падение VPN
    /// съедало прежний журнал целиком — тридцать четыре процесса вытесняли всё.
    func test_capacity_is_a_hundred_records() {
        XCTAssertEqual(Constants.eventLogCapacity, 100)

        let store = store()
        for index in 0..<120 { store.record([event("событие \(index)")]) }
        XCTAssertEqual(store.events.count, 100)
        XCTAssertEqual(store.events.first?.reasonText, "событие 119")
        XCTAssertEqual(store.events.last?.reasonText, "событие 20")
    }

    /// Причина уточняется у всех записей эпизода разом: процессов в нём десятки,
    /// и причина у них общая.
    func test_refine_touches_every_record_of_the_episode() {
        let store = store()
        let episode = UUID()
        let other = UUID()

        store.record([event("чужое", pid: 1, episodeID: other)])
        store.record([
            event("Подключение ещё не проверено", pid: 100, episodeID: episode),
            event("Подключение ещё не проверено", pid: 101, episodeID: episode),
        ])

        store.refine(episodeID: episode, reasonText: "Адрес 1.2.3.4 в чёрном списке", ip: "1.2.3.4")

        let refined = store.events.filter { $0.episodeID == episode }
        XCTAssertEqual(refined.count, 2)
        XCTAssertEqual(Set(refined.map(\.reasonText)), ["Адрес 1.2.3.4 в чёрном списке"])
        XCTAssertEqual(store.events.first(where: { $0.episodeID == other })?.reasonText, "чужое")
    }

    /// Эпизод, начавшийся до вердикта и закончившийся безопасным выходом, обязан
    /// сказать, чем кончился: без этого в журнале навсегда остаётся отговорка
    /// «подключение ещё не проверено», и завершение выглядит беспричинным.
    func test_resolution_is_written_to_the_episode() {
        let store = store()
        let episode = UUID()
        store.record([event("Подключение ещё не проверено", pid: 100, episodeID: episode)])

        store.refine(
            episodeID: episode,
            reasonText: "Подключение ещё не проверено",
            resolutionText: "проверка завершилась безопасным выходом: 1.2.3.4, KZ"
        )

        XCTAssertEqual(
            store.events.first?.resolutionText,
            "проверка завершилась безопасным выходом: 1.2.3.4, KZ"
        )
    }

    func test_event_renders_kind_and_reason() {
        let terminated = event("VPN не поднят")
        XCTAssertEqual(terminated.summaryText, "завершено — VPN не поднят")

        let blocked = KillEvent(
            episodeID: UUID(), date: Date(), targetName: "qwen", pid: 3,
            kind: .launchBlocked, reasonText: "VPN не поднят", ip: nil, country: nil
        )
        XCTAssertEqual(blocked.summaryText, "запуск запрещён — VPN не поднят")
    }

    func test_acronym_at_start_of_reason_is_not_lowercased() {
        // "VPN не поднят" не должно превращаться в "vPN не поднят":
        // первое слово из заглавных — аббревиатура, её регистр трогать нельзя.
        XCTAssertEqual(event("VPN не поднят").summaryText, "завершено — VPN не поднят")
    }

    func test_ordinary_reason_starts_lowercase_after_action() {
        let event = KillEvent(
            episodeID: UUID(), date: Date(), targetName: "nano", pid: 1,
            kind: .launchBlocked, reasonText: "Обнаружена страна KZ по данным ipinfo",
            ip: nil, country: nil
        )
        XCTAssertEqual(
            event.summaryText,
            "запуск запрещён — обнаружена страна KZ по данным ipinfo"
        )
    }

    func test_confirmation_source_is_carried_into_the_record() {
        let event = KillEvent(
            episodeID: UUID(), date: Date(), targetName: "nano", pid: 1,
            kind: .terminated, reasonText: "причина", ip: "1.2.3.4", country: "KZ",
            confirmedCountry: "KZ", confirmSource: "freeipapi"
        )
        XCTAssertEqual(event.confirmedCountry, "KZ")
        XCTAssertEqual(event.confirmSource, "freeipapi")
    }

    /// Потомок совпавшего процесса помечается: именно потомки объясняют,
    /// почему у одной цели десятки записей.
    func test_descendant_is_marked_with_its_parent() {
        let event = KillEvent(
            episodeID: UUID(), date: Date(), targetName: "claude", pid: 102,
            parentPID: 100, executablePath: "/opt/homebrew/bin/rg", isDescendant: true,
            kind: .terminated, reasonText: "причина", ip: nil, country: nil
        )
        XCTAssertTrue(event.isDescendant)
        XCTAssertEqual(event.parentPID, 100)
        XCTAssertEqual(event.executablePath, "/opt/homebrew/bin/rg")
    }

    func test_clear_empties_the_log() {
        let log = store()
        log.record([event("будет стёрто")])
        log.clear()
        XCTAssertTrue(log.events.isEmpty)
        XCTAssertTrue(store().events.isEmpty)
    }
}

final class UnsafeReasonTextTests: XCTestCase {

    func test_every_reason_has_non_empty_text() {
        let reasons: [UnsafeReason] = [
            .vpnAppNotChosen, .vpnAppNotRunning, .verificationPending,
            .geoUnavailable("timeout"), .blacklistedIP("1.2.3.4"),
            .blockedCountry(code: "RU", source: "ipinfo"),
            .confirmationUnavailable,
            .countryConflict(primary: "KZ", confirmed: "DE"),
            .notWhitelistedIP("1.2.3.4"),
            .notWhitelistedCountry("DE"),
        ]
        for reason in reasons {
            XCTAssertFalse(reason.displayText.isEmpty, "пустой текст у \(reason)")
        }
    }

    /// Текст видит пользователь в статусе, журнале и уведомлении — техническое
    /// имя перечисления туда попадать не должно.
    func test_whitelist_reasons_speak_russian() {
        XCTAssertEqual(
            UnsafeReason.notWhitelistedIP("203.0.113.28").displayText,
            "Адрес 203.0.113.28 не входит в белый список"
        )
        XCTAssertEqual(
            UnsafeReason.notWhitelistedCountry("DE").displayText,
            "Страна DE не входит в белый список"
        )
    }

    /// Непопадание в whitelist — сработавшая защита, а не отказ сервиса:
    /// жёлтой деградацией оно выглядеть не должно.
    func test_whitelist_reasons_are_not_degradation() {
        XCTAssertFalse(UnsafeReason.notWhitelistedIP("203.0.113.28").isDegradedRatherThanBlocked)
        XCTAssertFalse(UnsafeReason.notWhitelistedCountry("DE").isDegradedRatherThanBlocked)
        XCTAssertEqual(UnsafeReason.notWhitelistedCountry("DE").statusTitle, "Цели завершены")
    }

    func test_only_missing_confirmation_is_degraded() {
        XCTAssertTrue(UnsafeReason.confirmationUnavailable.isDegradedRatherThanBlocked)
        XCTAssertFalse(UnsafeReason.vpnAppNotRunning.isDegradedRatherThanBlocked)
        XCTAssertFalse(UnsafeReason.blockedCountry(code: "RU", source: "ipinfo")
            .isDegradedRatherThanBlocked)
        XCTAssertFalse(UnsafeReason.countryConflict(primary: "KZ", confirmed: "DE")
            .isDegradedRatherThanBlocked)
    }
}
