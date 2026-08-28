import XCTest
@testable import WetoShared
import WetoCore

/// Прогон контракта формата выгрузки из `shared/fixtures/journal-export.json`.
///
/// Тот же файл читает `linux/crates/weto-config/tests/export_fixture.rs`. Файл
/// выгрузки читает не только человек, но и агент, которому его отдают со словами
/// «разберись, почему завершились цели»: разные имена полей у двух платформ
/// означали бы, что разбирать придётся дважды, и расхождение всплыло бы
/// у пользователя, а не в тестах.
@MainActor
final class JournalExportFixtureTests: XCTestCase {

    private var contract: Contract!
    private var object: [String: Any]!
    private var text: String!

    override func setUp() async throws {
        contract = try loadContract()
        (object, text) = try makeFullyPopulatedExport()
    }

    func test_envelope_matches_the_shared_contract() {
        XCTAssertEqual(object["schemaVersion"] as? Int, contract.schemaVersion)
        assertKeys(of: object, equal: contract.envelopeKeys, at: "конверт")
        assertKeys(of: object["app"], equal: contract.appKeys, at: "app")
        assertKeys(of: object["settings"], equal: contract.settingsKeys, at: "settings")
    }

    /// Проверки — второй журнал в том же файле: «нажал и ничего не произошло»
    /// разбирают именно по нему.
    func test_check_matches_the_shared_contract() throws {
        let check = try XCTUnwrap((object["checks"] as? [[String: Any]])?.first)
        assertKeys(of: check, equal: contract.checkKeys, at: "проверка")

        XCTAssertTrue(contract.checkTriggers.contains(check["trigger"] as? String ?? ""))
        XCTAssertTrue(contract.checkOutcomes.contains(check["outcome"] as? String ?? ""))
        assertKeys(
            of: (check["services"] as? [[String: Any]])?.first,
            equal: contract.traceKeys, at: "трасса проверки"
        )
    }

    func test_event_matches_the_shared_contract() throws {
        let event = try firstEvent()
        assertKeys(of: event, equal: contract.eventKeys, at: "событие")

        let diagnostics = event["diagnostics"] as? [String: Any]
        assertKeys(of: diagnostics, equal: contract.diagnosticsKeys, at: "diagnostics")
        assertKeys(of: diagnostics?["staleness"], equal: contract.stalenessKeys, at: "staleness")

        let trace = (diagnostics?["services"] as? [[String: Any]])?.first
        assertKeys(of: trace, equal: contract.traceKeys, at: "трасса сервиса")

        XCTAssertTrue(contract.eventKinds.contains(event["kind"] as? String ?? ""))
        XCTAssertTrue(
            contract.stalenessCauses.contains(
                (diagnostics?["staleness"] as? [String: Any])?["cause"] as? String ?? ""
            )
        )
    }

    /// `SystemTime` в Rust по умолчанию сериализуется объектом, а не строкой:
    /// без этой проверки формат отметок разъехался бы молча.
    func test_timestamps_are_iso8601_in_utc() throws {
        let pattern = try NSRegularExpression(pattern: contract.timestampPattern)
        let event = try firstEvent()

        for field in contract.timestampFields {
            let value = (object[field] as? String)
                ?? (event[field] as? String)
                ?? ((event["diagnostics"] as? [String: Any])?[field] as? String)
            let stamp = try XCTUnwrap(value, "поля \(field) нет ни в конверте, ни в записи")
            let range = NSRange(stamp.startIndex..., in: stamp)
            XCTAssertNotNil(
                pattern.firstMatch(in: stamp, range: range),
                "отметка «\(stamp)» в поле \(field) не по ISO 8601"
            )
        }
    }

    /// Токен уходит заголовком, а заголовки в журнал не записываются вовсе.
    func test_export_never_carries_the_token_or_its_header() {
        for forbidden in contract.forbiddenSubstrings {
            XCTAssertFalse(
                text.contains(forbidden),
                "в выгрузке нашлось «\(forbidden)» — файл отдают в переписку"
            )
        }
        XCTAssertFalse(text.contains("очень-секретный-токен"))
    }

    func test_body_limit_is_the_shared_one() {
        XCTAssertEqual(GeoServiceTrace.bodyLimit, contract.bodyLimit)
    }

    // MARK: - Материал

    /// Случай заполнен целиком: Swift опускает nil-поля, serde печатает их как
    /// null, и на пустых полях списки ключей разъехались бы не по делу.
    private func makeFullyPopulatedExport() throws -> ([String: Any], String) {
        let suiteName = "com.weto.tests.\(UUID().uuidString)"
        let settings = SettingsStore(
            defaults: UserDefaults(suiteName: suiteName)!,
            secrets: InMemorySecretStore()
        )
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        settings.isEnabled = true
        settings.targets = ["/Users/square/.local/bin/claude"]
        settings.vpnAppRule = "su.ffg.happ"
        settings.blockedCountryCodes = ["RU"]
        settings.blockedIPRangeTexts = ["185.228.113.0/24"]
        settings.allowedCountryCodes = ["KZ"]
        settings.allowedIPRangeTexts = ["176.12.76.0/24"]
        settings.setIPInfoToken("очень-секретный-токен")

        let event = KillEvent(
            episodeID: UUID(),
            date: Date(timeIntervalSince1970: 1_787_000_000),
            targetName: "claude",
            pid: 92594,
            parentPID: 1,
            executablePath: "/Users/square/.local/bin/claude",
            isDescendant: true,
            kind: .terminated,
            reasonText: "Подключение ещё не проверено",
            resolutionText: "проверка завершилась безопасным выходом: 176.12.76.15, KZ",
            ip: "176.12.76.15",
            country: "KZ",
            confirmedCountry: "KZ",
            confirmSource: "freeipapi",
            diagnostics: KillDiagnostics(
                staleness: VerdictStaleness(
                    previousRevision: 3,
                    revision: 3,
                    previousFingerprint: "out=utun6/10.2.0.2",
                    fingerprint: "out=utun6/10.2.0.5"
                ),
                outgoingInterface: "utun6",
                outgoingAddress: "10.2.0.5",
                hasNetworkPath: true,
                vpnAppEntry: "su.ffg.happ",
                vpnAppStatus: "running",
                services: [
                    GeoServiceTrace(
                        service: "ipinfo",
                        url: "https://api.ipinfo.io/lite/me",
                        httpStatus: 200,
                        durationMilliseconds: 42,
                        body: #"{"ip":"176.12.76.15","country_code":"KZ"}"#,
                        failure: "нет",
                        fromCache: true,
                        cacheAgeSeconds: 7
                    )
                ],
                probedAt: Date(timeIntervalSince1970: 1_787_000_000),
                appVersion: "0.1.0"
            )
        )

        let check = CheckEvent(
            date: Date(timeIntervalSince1970: 1_787_000_050),
            trigger: .manual,
            outcome: .skippedProbeInFlight,
            fingerprint: "out=utun6/10.2.0.5",
            durationMilliseconds: 42,
            ip: "176.12.76.15",
            country: "KZ",
            confirmedCountry: "KZ",
            confirmSource: "freeipapi",
            services: [
                GeoServiceTrace(
                    service: "ipinfo",
                    url: "https://api.ipinfo.io/lite/me",
                    httpStatus: 200,
                    durationMilliseconds: 42,
                    body: #"{"ip":"176.12.76.15","country_code":"KZ"}"#,
                    failure: "нет",
                    fromCache: true,
                    cacheAgeSeconds: 7
                )
            ],
            detail: "проба уже в полёте"
        )

        let data = try JournalExporter.make(
            settings: settings,
            events: [event],
            checks: [check],
            at: Date(timeIntervalSince1970: 1_787_000_100),
            osVersion: "Version 26.0"
        ).encoded()

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return (object, String(data: data, encoding: .utf8) ?? "")
    }

    private func firstEvent() throws -> [String: Any] {
        try XCTUnwrap((object["events"] as? [[String: Any]])?.first)
    }

    private func assertKeys(
        of value: Any?,
        equal expected: [String],
        at place: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = Set((value as? [String: Any])?.keys.map { $0 } ?? [])
        XCTAssertEqual(
            actual, Set(expected),
            "ключи \(place) разошлись с общим контрактом", file: file, line: line
        )
    }

    private struct Contract: Decodable {
        let schemaVersion: Int
        let envelopeKeys: [String]
        let appKeys: [String]
        let settingsKeys: [String]
        let eventKeys: [String]
        let diagnosticsKeys: [String]
        let stalenessKeys: [String]
        let traceKeys: [String]
        let checkKeys: [String]
        let checkTriggers: [String]
        let checkOutcomes: [String]
        let stalenessCauses: [String]
        let eventKinds: [String]
        let timestampPattern: String
        let timestampFields: [String]
        let bodyLimit: Int
        let forbiddenSubstrings: [String]
    }

    /// Путь берётся от исходника теста, а не от бандла: фикстуры лежат вне
    /// `macos/`, и копировать их в ресурсы значило бы завести вторую копию.
    private func loadContract() throws -> Contract {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WetoSharedTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // macos
            .deletingLastPathComponent()   // корень репозитория
        let url = repoRoot.appendingPathComponent("shared/fixtures/journal-export.json")
        return try JSONDecoder().decode(Contract.self, from: Data(contentsOf: url))
    }
}
