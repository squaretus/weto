import XCTest
@testable import UpdateKitCore

final class UpdatePolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func info(latest: String, isNewer: Bool = true) -> UpdateInfo {
        UpdateInfo(
            currentVersion: "0.4.0",
            latestVersion: latest,
            releaseURL: "https://github.com/example/sample/releases/tag/v\(latest)",
            downloadURL: "https://github.com/example/sample/releases/download/v\(latest)/Sample.pkg",
            releaseNotes: nil,
            isNewer: isNewer
        )
    }

    func test_same_version_is_silent() {
        let outcome = UpdatePolicy.decide(
            latest: info(latest: "0.4.0", isNewer: false),
            deferral: .none,
            now: now
        )
        XCTAssertEqual(outcome, .silent)
    }

    func test_fresh_version_prompts() {
        XCTAssertEqual(
            UpdatePolicy.decide(latest: info(latest: "0.4.2"), deferral: .none, now: now),
            .prompt
        )
    }

    func test_skipped_version_is_silent() {
        let deferral = UpdateDeferral(skippedVersion: "0.4.2", remindAt: nil, isAutoInstallEnabled: false)
        XCTAssertEqual(UpdatePolicy.decide(latest: info(latest: "0.4.2"), deferral: deferral, now: now), .silent)
    }

    /// Пропуск снимается сам, когда выходит версия выше пропущенной —
    /// поэтому управлять им из настроек не нужно.
    func test_version_above_the_skipped_one_prompts_again() {
        let deferral = UpdateDeferral(skippedVersion: "0.4.2", remindAt: nil, isAutoInstallEnabled: false)
        XCTAssertEqual(UpdatePolicy.decide(latest: info(latest: "0.4.3"), deferral: deferral, now: now), .prompt)
    }

    func test_reminder_in_the_future_is_silent() {
        let deferral = UpdateDeferral(
            skippedVersion: nil,
            remindAt: now.addingTimeInterval(3600),
            isAutoInstallEnabled: false
        )
        XCTAssertEqual(UpdatePolicy.decide(latest: info(latest: "0.4.2"), deferral: deferral, now: now), .silent)
    }

    func test_expired_reminder_prompts() {
        let deferral = UpdateDeferral(
            skippedVersion: nil,
            remindAt: now.addingTimeInterval(-60),
            isAutoInstallEnabled: false
        )
        XCTAssertEqual(UpdatePolicy.decide(latest: info(latest: "0.4.2"), deferral: deferral, now: now), .prompt)
    }

    /// Перевод системных часов назад иначе запер бы обновления на произвольный срок.
    func test_reminder_further_than_six_hours_is_treated_as_expired() {
        let deferral = UpdateDeferral(
            skippedVersion: nil,
            remindAt: now.addingTimeInterval(7 * 3600),
            isAutoInstallEnabled: false
        )
        XCTAssertEqual(UpdatePolicy.decide(latest: info(latest: "0.4.2"), deferral: deferral, now: now), .prompt)
    }

    func test_auto_install_beats_skip_and_reminder() {
        let deferral = UpdateDeferral(
            skippedVersion: "0.4.2",
            remindAt: now.addingTimeInterval(3600),
            isAutoInstallEnabled: true
        )
        XCTAssertEqual(UpdatePolicy.decide(latest: info(latest: "0.4.2"), deferral: deferral, now: now), .install)
    }

    func test_auto_install_does_not_fire_without_a_newer_version() {
        let deferral = UpdateDeferral(skippedVersion: nil, remindAt: nil, isAutoInstallEnabled: true)
        XCTAssertEqual(
            UpdatePolicy.decide(latest: info(latest: "0.4.0", isNewer: false), deferral: deferral, now: now),
            .silent
        )
    }
}
