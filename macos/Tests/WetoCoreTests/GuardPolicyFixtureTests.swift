import XCTest
@testable import WetoCore

/// Прогон голден-фикстур политики из `shared/fixtures/guard-policy.json`.
///
/// Тот же файл читает `linux/crates/weto-core/tests/policy_fixtures.rs`. Это
/// единственный механизм, которым расхождение двух реализаций ловится машинно:
/// без него порядок проверок или трактовка «нет подтверждения» разъедутся тихо,
/// и заметить это можно будет только по невыключенному kill-switch на одной из ОС.
final class GuardPolicyFixtureTests: XCTestCase {

    func test_every_fixture_case_matches_the_policy() throws {
        let suite = try loadSuite()
        XCTAssertFalse(suite.cases.isEmpty, "фикстуры пусты — файл не найден или испорчен")

        for fixture in suite.cases {
            let actual = try decision(for: fixture)
            XCTAssertEqual(actual, fixture.expect.asDecision, "случай «\(fixture.name)»")
        }
    }

    // MARK: - Прогон

    private func decision(for fixture: Case) throws -> Decision {
        let config = try fixture.config.asGuardConfig()

        switch fixture.function {
        case "decide":
            guard let vpn = fixture.vpn?.asStatus, let geo = try fixture.geo?.asOutcome() else {
                throw Failure("случай «\(fixture.name)» для decide обязан задавать vpn и geo")
            }
            let signals = GuardSignals(isEnabled: fixture.isEnabled, vpn: vpn, geo: geo, config: config)
            return .some(GuardPolicy.decide(signals))

        case "decideLocal":
            guard let vpn = fixture.vpn?.asStatus else {
                throw Failure("случай «\(fixture.name)» для decideLocal обязан задавать vpn")
            }
            let local = GuardPolicy.decideLocal(isEnabled: fixture.isEnabled, vpn: vpn, config: config)
            return local.map(Decision.some) ?? .none

        case "pendingVerification":
            return .some(GuardPolicy.pendingVerification(isEnabled: fixture.isEnabled, config: config))

        default:
            throw Failure("неизвестная функция «\(fixture.function)» в случае «\(fixture.name)»")
        }
    }

    private func loadSuite() throws -> Suite {
        // Путь берётся от исходника теста, а не от бандла: фикстуры лежат вне
        // macos/, и копировать их в ресурсы значило бы завести вторую копию.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WetoCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // macos
            .deletingLastPathComponent()   // корень репозитория
        let url = repoRoot.appendingPathComponent("shared/fixtures/guard-policy.json")
        return try JSONDecoder().decode(Suite.self, from: Data(contentsOf: url))
    }

    // MARK: - Схема файла

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// `nil` у `decideLocal` — это отдельный исход, а не отсутствие данных.
    private enum Decision: Equatable {
        case none
        case some(GuardDecision)
    }

    private struct Suite: Decodable {
        let cases: [Case]
    }

    private struct Case: Decodable {
        let name: String
        let function: String
        let isEnabled: Bool
        let vpn: VPN?
        let geo: Geo?
        let config: Config
        let expect: Expect
    }

    private struct VPN: Decodable {
        let kind: String
        let isPrimary: Bool?

        var asStatus: VPNStatus {
            switch kind {
            case "down": return .down
            case "up": return .up(isPrimary: isPrimary ?? false)
            default: return .notConfigured
            }
        }
    }

    private struct Geo: Decodable {
        let kind: String
        let detail: String?
        let ip: String?
        let primaryCountry: String?
        let confirmedCountry: String?
        let confirmSource: String?

        func asOutcome() throws -> GeoOutcome {
            if kind == "unavailable" { return .unavailable(detail ?? "") }
            guard let ip, let primaryCountry else {
                throw Failure("\(kind) без ip или страны")
            }
            let reading = GeoReading(
                ip: ip,
                primaryCountry: primaryCountry,
                confirmedCountry: confirmedCountry,
                confirmSource: confirmSource.flatMap(ConfirmSource.init(rawValue:))
            )
            if kind == "degraded" { return .degraded(previous: reading, detail: detail ?? "") }
            return .resolved(reading)
        }
    }

    private struct Config: Decodable {
        let vpnID: String?
        let blockedCountries: [String]
        let blockedIPRanges: [String]
        let targets: [String]

        func asGuardConfig() throws -> GuardConfig {
            var ranges: [IPRange] = []
            for text in blockedIPRanges {
                guard let range = IPRange(text) else {
                    throw Failure("фикстуры содержат неразбираемый диапазон «\(text)»")
                }
                ranges.append(range)
            }
            return GuardConfig(
                vpnServiceID: vpnID,
                blockedCountries: Set(blockedCountries),
                blockedIPRanges: ranges,
                targets: targets
            )
        }
    }

    private struct Expect: Decodable {
        let decision: String
        let reason: Reason?

        var asDecision: Decision {
            switch decision {
            case "none": return .none
            case "safe": return .some(.safe)
            default: return .some(.kill(reason!.asUnsafeReason))
            }
        }
    }

    private struct Reason: Decodable {
        let kind: String
        let detail: String?
        let ip: String?
        let code: String?
        let source: String?
        let primary: String?
        let confirmed: String?

        var asUnsafeReason: UnsafeReason {
            switch kind {
            case "verificationPending": return .verificationPending
            case "vpnNotConfigured": return .vpnNotConfigured
            case "vpnDown": return .vpnDown
            case "vpnNotPrimary": return .vpnNotPrimary
            case "geoUnavailable": return .geoUnavailable(detail ?? "")
            case "blacklistedIP": return .blacklistedIP(ip ?? "")
            case "blockedCountry": return .blockedCountry(code: code ?? "", source: source ?? "")
            case "confirmationUnavailable": return .confirmationUnavailable
            case "countryConflict":
                return .countryConflict(primary: primary ?? "", confirmed: confirmed ?? "")
            default:
                fatalError("неизвестная причина «\(kind)» в фикстурах")
            }
        }
    }
}
