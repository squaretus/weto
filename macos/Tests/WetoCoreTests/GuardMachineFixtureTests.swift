import XCTest
@testable import WetoCore

/// Прогон голден-фикстур машины состояний из `shared/fixtures/guard-transitions.json`.
///
/// Тот же файл прочтёт Rust-реализация в плане порта паузы. Политика уже пришпилена
/// фикстурой, но политика отвечает про один момент; расхождение двух реализаций живёт
/// в переходах — в том, какая фаза стоит, когда начинается пауза и как считается потолок.
/// Без общего файла это разъехалось бы тихо: обе стороны остались бы «зелёными».
final class GuardMachineFixtureTests: XCTestCase {

    func test_every_fixture_case_matches_the_machine() throws {
        let suite = try loadSuite()
        XCTAssertEqual(suite.version, 2, "версия фикстур разъехалась с раннером")
        XCTAssertFalse(suite.cases.isEmpty, "фикстуры пусты — файл не найден или испорчен")

        let reading = suite.reading.asReading
        for fixture in suite.cases {
            var machine = GuardMachine(
                phase: try fixture.start.phase(reading: reading),
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

    /// Ожидаемая фаза: сверяются `kind`, а также `cause`, `reason` и `evidence.kind`.
    /// Узел, не заданный вовсе, раннер прощает и сверяет один `kind` — но файл этой
    /// поблажкой не пользуется нигде: нагрузка выписана у каждой ожидаемой фазы,
    /// иначе проверка выродилась бы в сверку вида, и подменённая причина паузы
    /// прошла бы мимо обоих раннеров сразу.
    /// Полезная нагрузка заданного узла (`detail`, `observed`, `ip`, `code`, `source`,
    /// `primary`, `confirmed`, `cause`) обязательна: молчаливое умолчание в пустую строку
    /// означало бы, что Rust-раннер разойдётся с этим на первом же случае с нагрузкой,
    /// и оба останутся зелёными.
    /// Момент постановки на паузу не сверяется — он вычисляется из `at` шага, и сверять
    /// его значило бы сверять раннер с самим собой.
    private struct Phase: Decodable {
        let kind: String
        let cause: String?
        let evidence: Evidence?
        let reason: Reason?

        /// Стартовая фаза случая. `paused` стартовой не бывает: у неё есть момент
        /// постановки, а он в файле не задаётся — такие случаи начинаются с шага,
        /// который на паузу и ставит. У `verifying` момента нет вовсе (цели в ней
        /// работают, и считать от неё нечего), поэтому стартовой она быть может.
        func phase(reading: GeoReading) throws -> GuardPhase {
            switch kind {
            case "disabled": return .disabled
            case "verifying": return .verifying(cause: try parsedCause)
            case "protected": return .protected(reading)
            case "interference":
                guard let reason else { throw Failure("стартовая фаза interference без причины") }
                return .interference(reading, reason: try reason.asUnproven)
            case "danger":
                guard let evidence else { throw Failure("стартовая фаза danger без улики") }
                return .danger(try evidence.asEvidence)
            default:
                throw Failure("фаза «\(kind)» стартовой быть не может")
            }
        }

        private var parsedCause: VerdictStaleness.Cause {
            get throws {
                guard let cause, let parsed = VerdictStaleness.Cause(rawValue: cause) else {
                    throw Failure("фаза verifying с неизвестной причиной «\(cause ?? "—")»")
                }
                return parsed
            }
        }

        func matches(_ actual: GuardPhase) -> Bool {
            switch (kind, actual) {
            case ("disabled", .disabled): return true
            case ("verifying", .verifying(let actualCause)):
                guard cause != nil else { return true }
                return (try? parsedCause) == actualCause
            case ("protected", .protected): return true
            case ("interference", .interference(_, let actualReason)):
                guard let reason else { return true }
                return (try? reason.asUnproven) == actualReason
            case ("paused", .paused(_, let actualReason)):
                guard let reason else { return true }
                return (try? reason.asUnproven) == actualReason
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
            case "degraded":
                guard let detail else { throw Failure("degraded без подробности") }
                return .degraded(previous: reading, detail: detail)
            case "unavailable":
                guard let detail else { throw Failure("unavailable без подробности") }
                return .unavailable(detail)
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

        var asUnproven: UnprovenReason {
            get throws {
                switch kind {
                case "geoUnavailable":
                    guard let detail else { throw Failure("geoUnavailable без подробности") }
                    return .geoUnavailable(detail)
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
                case "blacklistedIP":
                    guard let ip else { throw Failure("blacklistedIP без адреса") }
                    return .blacklistedIP(ip)
                case "blockedCountry":
                    guard let code, let source else { throw Failure("blockedCountry без страны или источника") }
                    return .blockedCountry(code: code, source: source)
                case "countryConflict":
                    guard let primary, let confirmed else { throw Failure("countryConflict без пары стран") }
                    return .countryConflict(primary: primary, confirmed: confirmed)
                case "notWhitelistedIP":
                    guard let ip else { throw Failure("notWhitelistedIP без адреса") }
                    return .notWhitelistedIP(ip)
                case "notWhitelistedCountry":
                    guard let code else { throw Failure("notWhitelistedCountry без страны") }
                    return .notWhitelistedCountry(code)
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
