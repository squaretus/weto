import XCTest
@testable import WetoCore

/// Прогон голден-фикстур машины состояний из `shared/fixtures/guard-transitions.json`.
///
/// Тот же файл прочтёт Rust-реализация в плане порта паузы. Политика уже пришпилена
/// фикстурой, но политика отвечает про один момент; расхождение двух реализаций живёт
/// в переходах — в терпимости к молчанию, в момент постановки на паузу и в потолке.
/// Без общего файла это разъехалось бы тихо: обе стороны остались бы «зелёными».
final class GuardMachineFixtureTests: XCTestCase {

    func test_every_fixture_case_matches_the_machine() throws {
        let suite = try loadSuite()
        XCTAssertEqual(suite.version, 1, "версия фикстур разъехалась с раннером")
        XCTAssertFalse(suite.cases.isEmpty, "фикстуры пусты — файл не найден или испорчен")

        let reading = suite.reading.asReading
        for fixture in suite.cases {
            var machine = GuardMachine(
                phase: try fixture.start.phase(reading: reading),
                tolerance: fixture.tolerance,
                pauseCeiling: fixture.ceilingSeconds
            )
            for step in fixture.steps {
                let effect = machine.apply(
                    try step.input.asInput(reading: reading),
                    at: Date(timeIntervalSince1970: step.at)
                )
                XCTAssertEqual(effect, try step.effect.asEffect, "«\(fixture.name)» @\(step.at): эффект")
                XCTAssertTrue(step.phase.matches(machine.phase), "«\(fixture.name)» @\(step.at): фаза \(machine.phase)")
            }
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
        let url = repoRoot.appendingPathComponent("shared/fixtures/guard-transitions.json")
        return try JSONDecoder().decode(Suite.self, from: Data(contentsOf: url))
    }

    // MARK: - Схема файла

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private struct Suite: Decodable {
        let version: Int
        let reading: Reading
        let cases: [Case]
    }

    private struct Case: Decodable {
        let name: String
        let tolerance: Int
        let ceilingSeconds: TimeInterval
        let start: Phase
        let steps: [Step]
    }

    private struct Step: Decodable {
        let at: TimeInterval
        let input: Input
        let phase: Phase
        let effect: String
    }

    private struct Reading: Decodable {
        let ip: String
        let primaryCountry: String
        let confirmedCountry: String?
        let confirmSource: String?

        var asReading: GeoReading {
            GeoReading(
                ip: ip,
                primaryCountry: primaryCountry,
                confirmedCountry: confirmedCountry,
                confirmSource: confirmSource.flatMap(ConfirmSource.init(rawValue:))
            )
        }
    }

    /// Ожидаемая фаза: сверяются `kind`, а также `failures` и `evidence.kind`, если заданы.
    /// Момент постановки на паузу не сверяется — он вычисляется из `at` шага, и сверять
    /// его значило бы сверять раннер с самим собой.
    private struct Phase: Decodable {
        let kind: String
        let failures: Int?
        let evidence: Evidence?
        let reason: Reason?

        /// Стартовая фаза случая. `verifying` и `paused` в фикстурах стартовыми не бывают:
        /// у них есть момент постановки, а он в файле не задаётся — такие случаи
        /// начинаются с шага, который на паузу и ставит.
        func phase(reading: GeoReading) throws -> GuardPhase {
            switch kind {
            case "disabled": return .disabled
            case "protected": return .protected(reading)
            case "interference":
                return .interference(
                    reading,
                    reason: try (reason ?? Reason.geoUnavailable).asUnproven,
                    failures: failures ?? 0
                )
            case "danger":
                guard let evidence else { throw Failure("стартовая фаза danger без улики") }
                return .danger(try evidence.asEvidence)
            default:
                throw Failure("фаза «\(kind)» стартовой быть не может")
            }
        }

        func matches(_ actual: GuardPhase) -> Bool {
            switch (kind, actual) {
            case ("disabled", .disabled): return true
            case ("verifying", .verifying): return true
            case ("protected", .protected): return true
            case ("interference", .interference(_, _, let actualFailures)):
                return failures.map { $0 == actualFailures } ?? true
            case ("paused", .paused): return true
            case ("danger", .danger(let actualEvidence)):
                guard let evidence else { return true }
                return (try? evidence.asEvidence) == actualEvidence
            default: return false
            }
        }
    }

    private struct Input: Decodable {
        let kind: String
        let cause: String?
        let decision: Decision?
        let geo: Geo?
        let evidence: Evidence?

        func asInput(reading: GeoReading) throws -> GuardInput {
            switch kind {
            case "tick": return .tick
            case "disarmed": return .disarmed
            case "verdictLost":
                guard let cause, let parsed = VerdictStaleness.Cause(rawValue: cause) else {
                    throw Failure("verdictLost с неизвестной причиной «\(cause ?? "—")»")
                }
                return .verdictLost(parsed)
            case "evidence":
                guard let evidence else { throw Failure("вход evidence без улики") }
                return .evidence(try evidence.asEvidence)
            case "verdict":
                guard let decision, let geo else { throw Failure("вход verdict без решения или гео") }
                return .verdict(try decision.asDecision, geo: try geo.asOutcome(reading: reading))
            case "reassessment":
                guard let decision else { throw Failure("вход reassessment без решения") }
                return .reassessment(try decision.asDecision, reading: reading)
            default:
                throw Failure("неизвестный вход «\(kind)»")
            }
        }
    }

    private struct Decision: Decodable {
        let kind: String
        let reason: Reason?
        let evidence: Evidence?

        var asDecision: GuardDecision {
            get throws {
                switch kind {
                case "safe": return .safe
                case "unproven":
                    guard let reason else { throw Failure("unproven без причины") }
                    return .unproven(try reason.asUnproven)
                case "kill":
                    guard let evidence else { throw Failure("kill без улики") }
                    return .kill(try evidence.asEvidence)
                default:
                    throw Failure("неизвестное решение «\(kind)»")
                }
            }
        }
    }

    private struct Geo: Decodable {
        let kind: String
        let detail: String?
        let observed: String?

        func asOutcome(reading: GeoReading) throws -> GeoOutcome {
            switch kind {
            case "resolved": return .resolved(reading)
            case "degraded": return .degraded(previous: reading, detail: detail ?? "")
            case "unavailable": return .unavailable(detail ?? "")
            case "addressChanged":
                guard let observed else { throw Failure("addressChanged без наблюдаемого адреса") }
                return .addressChanged(observed: observed, previous: reading)
            default:
                throw Failure("неизвестное гео «\(kind)»")
            }
        }
    }

    private struct Reason: Decodable {
        let kind: String
        let detail: String?
        let observed: String?

        static let geoUnavailable = Reason(kind: "geoUnavailable", detail: "", observed: nil)

        var asUnproven: UnprovenReason {
            get throws {
                switch kind {
                case "geoUnavailable": return .geoUnavailable(detail ?? "")
                case "addressChanged":
                    guard let observed else { throw Failure("addressChanged без наблюдаемого адреса") }
                    return .addressChanged(observed: observed)
                case "confirmationUnavailable": return .confirmationUnavailable
                default:
                    throw Failure("неизвестная unproven-причина «\(kind)»")
                }
            }
        }
    }

    private struct Evidence: Decodable {
        let kind: String
        let ip: String?
        let code: String?
        let source: String?
        let primary: String?
        let confirmed: String?

        var asEvidence: UnsafeEvidence {
            get throws {
                switch kind {
                case "vpnAppNotRunning": return .vpnAppNotRunning
                case "blacklistedIP": return .blacklistedIP(ip ?? "")
                case "blockedCountry": return .blockedCountry(code: code ?? "", source: source ?? "")
                case "countryConflict":
                    return .countryConflict(primary: primary ?? "", confirmed: confirmed ?? "")
                case "notWhitelistedIP": return .notWhitelistedIP(ip ?? "")
                case "notWhitelistedCountry": return .notWhitelistedCountry(code ?? "")
                case "pauseExpired": return .pauseExpired
                default:
                    throw Failure("неизвестная улика «\(kind)»")
                }
            }
        }
    }
}

private extension String {
    var asEffect: GuardEffect {
        get throws {
            switch self {
            case "none": return .none
            case "pause": return .pause
            case "resume": return .resume
            case "terminate": return .terminate
            default:
                struct UnknownEffect: Error, CustomStringConvertible {
                    let description: String
                }
                throw UnknownEffect(description: "неизвестный эффект «\(self)»")
            }
        }
    }
}
