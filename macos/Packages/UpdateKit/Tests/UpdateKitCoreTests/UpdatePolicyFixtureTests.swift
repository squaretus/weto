import XCTest
@testable import UpdateKitCore

/// Прогон голден-фикстур политики показа из `shared/fixtures/update-policy.json`.
///
/// Тот же файл читает `linux/crates/weto-update/tests/policy_fixtures.rs`.
/// Правила пропуска и отсрочки оплачены опытом, и разъехаться между платформами
/// они не имеют права: пользователь, пропустивший версию на одной ОС, ждёт того же
/// поведения на другой.
final class UpdatePolicyFixtureTests: XCTestCase {

    func test_every_fixture_case_matches_the_policy() throws {
        let suite = try loadSuite()
        XCTAssertFalse(suite.cases.isEmpty, "фикстуры пусты — файл не найден или испорчен")

        let now = Date(timeIntervalSince1970: suite.now)

        for fixture in suite.cases {
            let outcome = UpdatePolicy.decide(
                latest: fixture.asUpdateInfo,
                deferral: fixture.deferral.asDeferral,
                now: now
            )
            XCTAssertEqual(outcome, fixture.expected, "случай «\(fixture.name)»")
        }
    }

    private func loadSuite() throws -> Suite {
        // Путь берётся от исходника теста: фикстуры лежат вне macos/,
        // и копировать их в ресурсы значило бы завести вторую копию контракта.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UpdateKitCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // UpdateKit
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // macos
            .deletingLastPathComponent()   // корень репозитория
        let url = repoRoot.appendingPathComponent("shared/fixtures/update-policy.json")
        return try JSONDecoder().decode(Suite.self, from: Data(contentsOf: url))
    }

    private struct Suite: Decodable {
        let now: TimeInterval
        let cases: [Case]
    }

    private struct Case: Decodable {
        let name: String
        let latestVersion: String
        let isNewer: Bool
        let deferral: Deferral
        let outcome: String

        var asUpdateInfo: UpdateInfo {
            UpdateInfo(
                currentVersion: "0.4.0",
                latestVersion: latestVersion,
                releaseURL: "https://example.com/releases/tag/v\(latestVersion)",
                downloadURL: "https://example.com/releases/download/v\(latestVersion)/Sample.pkg",
                releaseNotes: nil,
                isNewer: isNewer
            )
        }

        var expected: UpdatePolicy.Outcome {
            switch outcome {
            case "prompt": return .prompt
            case "install": return .install
            default: return .silent
            }
        }
    }

    private struct Deferral: Decodable {
        let skippedVersion: String?
        let remindAt: TimeInterval?
        let autoInstall: Bool

        var asDeferral: UpdateDeferral {
            UpdateDeferral(
                skippedVersion: skippedVersion,
                remindAt: remindAt.map { Date(timeIntervalSince1970: $0) },
                isAutoInstallEnabled: autoInstall
            )
        }
    }
}
