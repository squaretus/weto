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

    func test_preview_returns_at_most_configured_count() {
        let store = EventLogStore(defaults: defaults)
        for index in 0..<20 { store.record(event("событие \(index)")) }
        XCTAssertEqual(store.preview.count, Constants.eventLogPreviewCount)
        XCTAssertEqual(store.preview.first?.reasonText, "событие 19")
    }

    func test_capacity_is_ten_records() {
        // Требование владельца: журнал держит ровно десять последних записей.
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
            .vpnNotConfigured, .vpnDown, .vpnNotPrimary,
            .geoUnavailable("timeout"), .blacklistedIP("1.2.3.4"),
            .blockedCountry(code: "RU", source: "ipinfo"),
            .confirmationUnavailable,
            .countryConflict(primary: "KZ", confirmed: "DE"),
        ]
        for reason in reasons {
            XCTAssertFalse(reason.displayText.isEmpty, "пустой текст у \(reason)")
        }
    }

    func test_only_missing_confirmation_is_degraded() {
        XCTAssertTrue(UnsafeReason.confirmationUnavailable.isDegradedRatherThanBlocked)
        XCTAssertFalse(UnsafeReason.vpnDown.isDegradedRatherThanBlocked)
        XCTAssertFalse(UnsafeReason.blockedCountry(code: "RU", source: "ipinfo")
            .isDegradedRatherThanBlocked)
        XCTAssertFalse(UnsafeReason.countryConflict(primary: "KZ", confirmed: "DE")
            .isDegradedRatherThanBlocked)
    }
}
