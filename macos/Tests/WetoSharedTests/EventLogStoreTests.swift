import XCTest
@testable import WetoShared
import WetoCore

@MainActor
final class EventLogStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "com.weto.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    private func event(_ reason: String, pids: [Int32] = [42]) -> KillEvent {
        KillEvent(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            targetNames: ["TextEdit"],
            kind: .terminated,
            reasonText: reason,
            ip: "203.0.113.28",
            country: "KZ",
            killedPIDs: pids
        )
    }

    func test_new_store_is_empty() {
        XCTAssertTrue(EventLogStore(defaults: defaults).events.isEmpty)
    }

    func test_recorded_event_appears_first() {
        let store = EventLogStore(defaults: defaults)
        store.record(event("первое"))
        store.record(event("второе"))
        XCTAssertEqual(store.events.map(\.reasonText), ["второе", "первое"])
    }

    func test_events_survive_a_new_store_over_same_defaults() {
        EventLogStore(defaults: defaults).record(event("сохранённое"))
        XCTAssertEqual(EventLogStore(defaults: defaults).events.map(\.reasonText), ["сохранённое"])
    }

    func test_ring_buffer_drops_oldest_beyond_capacity() {
        let store = EventLogStore(defaults: defaults)
        for index in 0..<(Constants.eventLogCapacity + 10) {
            store.record(event("событие \(index)"))
        }
        XCTAssertEqual(store.events.count, Constants.eventLogCapacity)
        XCTAssertEqual(store.events.first?.reasonText, "событие \(Constants.eventLogCapacity + 9)")
        XCTAssertEqual(store.events.last?.reasonText, "событие 10")
    }

    func test_capacity_is_ten_records() {

        XCTAssertEqual(Constants.eventLogCapacity, 10)

        let store = EventLogStore(defaults: defaults)
        for index in 0..<25 { store.record(event("событие \(index)")) }
        XCTAssertEqual(store.events.count, 10)
        XCTAssertEqual(store.events.first?.reasonText, "событие 24")
        XCTAssertEqual(store.events.last?.reasonText, "событие 15")
    }

    func test_event_renders_target_kind_and_reason() {
        let terminated = KillEvent(
            date: Date(), targetNames: ["TextEdit", "nano"], kind: .terminated,
            reasonText: "VPN не поднят", ip: "1.2.3.4", country: "KZ", killedPIDs: [1, 2]
        )
        XCTAssertEqual(terminated.targetsText, "TextEdit, nano")
        XCTAssertEqual(terminated.summaryText, "завершено — VPN не поднят")

        let blocked = KillEvent(
            date: Date(), targetNames: ["qwen"], kind: .launchBlocked,
            reasonText: "VPN не поднят", ip: nil, country: nil, killedPIDs: [3]
        )
        XCTAssertEqual(blocked.summaryText, "запуск запрещён — VPN не поднят")
    }

    func test_acronym_at_start_of_reason_is_not_lowercased() {
        // "VPN не поднят" не должно превращаться в "vPN не поднят":
        // первое слово из заглавных — аббревиатура, её регистр трогать нельзя.
        let event = KillEvent(
            date: Date(), targetNames: ["nano"], kind: .terminated,
            reasonText: "VPN не поднят", ip: nil, country: nil, killedPIDs: [1]
        )
        XCTAssertEqual(event.summaryText, "завершено — VPN не поднят")
    }

    func test_ordinary_reason_starts_lowercase_after_action() {
        let event = KillEvent(
            date: Date(), targetNames: ["nano"], kind: .launchBlocked,
            reasonText: "Обнаружена страна KZ по данным ipinfo",
            ip: nil, country: nil, killedPIDs: [1]
        )
        XCTAssertEqual(
            event.summaryText,
            "запуск запрещён — обнаружена страна KZ по данным ipinfo"
        )
    }

    func test_confirmation_source_is_carried_into_the_record() {
        let event = KillEvent(
            date: Date(), targetNames: ["nano"], kind: .terminated,
            reasonText: "причина", ip: "1.2.3.4", country: "KZ",
            confirmedCountry: "KZ", confirmSource: "freeipapi", killedPIDs: [1]
        )
        XCTAssertEqual(event.confirmedCountry, "KZ")
        XCTAssertEqual(event.confirmSource, "freeipapi")
    }

    func test_event_without_names_still_renders() {
        let event = KillEvent(
            date: Date(), targetNames: [], kind: .terminated,
            reasonText: "причина", ip: nil, country: nil, killedPIDs: []
        )
        XCTAssertEqual(event.targetsText, "неизвестная цель")
    }

    func test_clear_empties_the_log() {
        let store = EventLogStore(defaults: defaults)
        store.record(event("будет стёрто"))
        store.clear()
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertTrue(EventLogStore(defaults: defaults).events.isEmpty)
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
