import XCTest
@testable import WetoShared
import WetoCore

@MainActor
final class JournalExportTests: XCTestCase {

    private var suiteName: String!
    private var settings: SettingsStore!

    override func setUp() async throws {
        suiteName = "com.weto.tests.\(UUID().uuidString)"
        settings = SettingsStore(
            defaults: UserDefaults(suiteName: suiteName)!,
            secrets: InMemorySecretStore()
        )
        settings.isEnabled = true
        settings.targets = ["/Users/square/.local/bin/claude"]
        settings.vpnAppRule = "su.ffg.happ"
        settings.blockedCountryCodes = ["RU"]
        settings.allowedCountryCodes = ["KZ"]
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    private func event(reason: String = "Подключение ещё не проверено") -> KillEvent {
        KillEvent(
            episodeID: UUID(),
            date: Date(timeIntervalSince1970: 1_700_000_000),
            targetName: "claude",
            pid: 92594,
            parentPID: 1,
            executablePath: "/Users/square/.local/bin/claude",
            kind: .terminated,
            reasonText: reason,
            ip: "176.12.76.15",
            country: "KZ",
            diagnostics: KillDiagnostics(
                staleness: VerdictStaleness(
                    previousRevision: 3,
                    revision: 3,
                    previousFingerprint: "out=utun6/10.2.0.2",
                    fingerprint: "out=utun6/10.2.0.5"
                ),
                outgoingInterface: "utun6",
                outgoingAddress: "10.2.0.5",
                services: [
                    GeoServiceTrace(
                        service: "ipinfo",
                        url: "https://api.ipinfo.io/lite/me",
                        httpStatus: 200,
                        durationMilliseconds: 42,
                        body: #"{"ip":"176.12.76.15","country_code":"KZ"}"#
                    )
                ]
            )
        )
    }

    /// Настройки в файле нужны ради того, зачем его и выгружают: по одним событиям
    /// не понять, что было настроено в тот момент.
    func test_export_carries_the_settings_of_the_moment() throws {
        let export = JournalExporter.make(settings: settings, events: [event()])

        XCTAssertEqual(export.settings.targets, ["/Users/square/.local/bin/claude"])
        XCTAssertEqual(export.settings.vpnAppRule, "su.ffg.happ")
        XCTAssertEqual(export.settings.blockedCountries, ["RU"])
        XCTAssertEqual(export.settings.allowedCountries, ["KZ"])
        XCTAssertTrue(export.settings.isEnabled)
    }

    /// Токен не поле настроек, а отдельное хранилище, и в выгрузку он не попадает
    /// ни при каких обстоятельствах: файл уходит в переписку.
    func test_token_never_reaches_the_export() throws {
        settings.setIPInfoToken("очень-секретный-токен")

        let data = try JournalExporter.make(settings: settings, events: [event()]).encoded()
        let text = String(data: data, encoding: .utf8) ?? ""

        XCTAssertFalse(text.contains("очень-секретный-токен"))
        XCTAssertTrue(text.contains("\"hasIPInfoToken\" : true"), "но факт наличия токена полезен")
    }

    /// Разбор «почему завершились цели» начинается с этих полей, поэтому они
    /// обязаны переживать сериализацию.
    func test_diagnostics_survive_the_round_trip() throws {
        let data = try JournalExporter.make(settings: settings, events: [event()]).encoded()

        let restored = try JournalExport.decode(data)
        let diagnostics = restored.events.first?.diagnostics

        XCTAssertEqual(diagnostics?.staleness?.cause, .networkChanged)
        XCTAssertEqual(diagnostics?.staleness?.previousFingerprint, "out=utun6/10.2.0.2")
        XCTAssertEqual(diagnostics?.outgoingInterface, "utun6")
        XCTAssertEqual(diagnostics?.services.first?.httpStatus, 200)
        XCTAssertEqual(
            diagnostics?.services.first?.body,
            #"{"ip":"176.12.76.15","country_code":"KZ"}"#
        )
    }

    /// Сырое тело обрезается: ответ гео-сервиса — сотни байт, а страница-заглушка
    /// провайдера бывает мегабайтом, и в журнале ей не место.
    func test_oversized_body_is_trimmed() {
        let huge = String(repeating: "я", count: GeoServiceTrace.bodyLimit * 2)
        let trace = GeoServiceTrace(service: "ipinfo", url: "https://api.ipinfo.io/lite/me", body: huge)

        XCTAssertEqual(trace.body?.count, GeoServiceTrace.bodyLimit + "…(обрезано)".count)
    }

    /// Файл читают и человек, и агент: две выгрузки одного состояния обязаны
    /// отличаться только событиями, а не порядком ключей.
    func test_export_is_stable_between_runs() throws {
        let moment = Date(timeIntervalSince1970: 1_700_000_000)
        let events = [event()]

        let first = try JournalExporter.make(settings: settings, events: events, at: moment, osVersion: "26.0").encoded()
        let second = try JournalExporter.make(settings: settings, events: events, at: moment, osVersion: "26.0").encoded()

        XCTAssertEqual(first, second)
    }

    func test_file_name_carries_the_moment() {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 27
        components.hour = 18
        components.minute = 30
        let moment = Calendar.current.date(from: components)!

        XCTAssertEqual(JournalExport.fileName(at: moment), "weto-journal-2026-08-27-1830.json")
    }
}
