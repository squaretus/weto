import XCTest
@testable import WetoCLI
import WetoCore
import WetoShared
import WetoSystem

/// Команды настроек против временного набора и временного каталога: правка
/// обязана лечь туда же и тем же путём, что правка из окна.
@MainActor
final class CLICommandsTests: XCTestCase {

    private var h: CLIHarness!

    override func setUp() async throws {
        h = CLIHarness()
    }

    override func tearDown() async throws {
        h.tearDown()
    }

    /// Вторая копия CLI над тем же набором — так видит правку работающая охрана.
    private func reopened() -> SettingsStore {
        SettingsStore(defaults: h.defaults, secrets: FileSecretStore(directory: h.paths.dataDirectory))
    }

    // MARK: - Цели

    func test_target_add_list_and_remove() {
        XCTAssertEqual(h.run("target add claude"), ExitCode.success)
        XCTAssertEqual(reopened().targets, ["claude"])
        XCTAssertEqual(h.output.lines.suffix(2), [
            "Цель добавлена: claude",
            "  бинарник: /Users/me/.local/share/claude/versions/2.1.228",
        ])

        // Вид строк — общий с Linux: имя и запись, под ними разрешение.
        h.run("target list")
        XCTAssertEqual(h.output.lines.suffix(2), [
            "claude (claude)",
            "  бинарник: /Users/me/.local/share/claude/versions/2.1.228",
        ])

        XCTAssertEqual(h.run("target remove claude"), ExitCode.success)
        XCTAssertTrue(reopened().targets.isEmpty)
        h.run("target list")
        XCTAssertEqual(h.output.lines.last, "Цели не выбраны — охрана ничего не завершает")
    }

    func test_an_unresolved_target_is_added_with_the_window_hint() {
        XCTAssertEqual(h.run("target add codex"), ExitCode.success)
        XCTAssertEqual(h.output.lines.suffix(2), [
            "Цель добавлена: codex",
            "  не найдено по имени — укажите полный путь к файлу",
        ])
    }

    /// Тексты и коды отказов — общие с Linux: формат — 2, конфликт — 1.
    func test_refusals_share_texts_and_codes_with_linux() {
        XCTAssertEqual(h.run("vpn set su.ffg.happ"), ExitCode.success)
        XCTAssertEqual(h.cli.execute(.targetAdd("  ")), ExitCode.usage)
        XCTAssertEqual(h.output.errors.last, "введите имя команды или путь")
        XCTAssertEqual(h.cli.execute(.vpnSet(" ", .automatic)), ExitCode.usage)
        XCTAssertEqual(h.output.errors.last, "введите имя команды или путь")
        XCTAssertEqual(h.run("target add su.ffg.happ"), ExitCode.failure)
        XCTAssertEqual(h.output.errors.last, "это выбранное VPN-приложение — охрана следит за ним, а не завершает его")
        XCTAssertEqual(h.run("vpn set --tunnel wg/0"), ExitCode.usage)
        XCTAssertEqual(h.output.errors.last, "имя интерфейса — от 1 до 15 символов: латиница, цифры, «_», «.» и «-»")
        XCTAssertEqual(h.run("blacklist remove NL"), ExitCode.failure)
        XCTAssertEqual(h.output.errors.last, "такой записи нет в списке")
    }

    func test_help_ends_with_the_version() {
        XCTAssertEqual(h.run("help"), ExitCode.success)
        XCTAssertTrue(h.output.lines.first?.hasPrefix("weto — охрана целей по VPN из терминала") ?? false)
        XCTAssertFalse(h.output.lines.joined().contains("weto-cli "), "команда называется weto")
        XCTAssertEqual(h.output.lines, [CommandParser.helpText(version: "0.2.0")])
        XCTAssertTrue(h.output.lines.last?.hasSuffix("\nВерсия: 0.2.0") ?? false)
    }

    func test_version_names_the_command_and_the_build() {
        XCTAssertEqual(h.run("version"), ExitCode.success)
        XCTAssertEqual(h.output.lines, ["weto 0.2.0"])
    }

    /// Справка по объекту по просьбе — в stdout и с кодом 0; без действия — код 2 у разбора.
    func test_object_help_on_request_goes_to_stdout() {
        XCTAssertEqual(h.run("vpn help"), ExitCode.success)
        XCTAssertEqual(h.output.lines, [CommandParser.objectHelp(.vpn)])
    }

    /// Для скрипта без охраны stdout пуст: текст — в stderr, код 3.
    func test_status_json_without_a_guard_leaves_stdout_empty() {
        XCTAssertEqual(h.run("status --json"), ExitCode.notRunning)
        XCTAssertTrue(h.output.lines.isEmpty)
        XCTAssertEqual(h.output.errors, [StatusText.notRunning])
    }

    func test_a_duplicate_target_is_refused() {
        h.run("target add claude")
        XCTAssertEqual(h.run("target add claude"), ExitCode.failure)
        XCTAssertEqual(h.output.errors.last, "такая цель уже есть в списке")
        XCTAssertEqual(reopened().targets, ["claude"])
    }

    /// Охрана не завершает собственный источник защиты — как и в окне.
    func test_the_vpn_app_is_not_added_as_a_target() {
        h.run("vpn set su.ffg.happ")
        XCTAssertEqual(h.run("target add su.ffg.happ"), ExitCode.failure)
        XCTAssertTrue(reopened().targets.isEmpty)
    }

    /// Цель снимается и по имени из `target list` — записью bundle id набирать неудобно.
    func test_a_target_is_removed_by_its_name() {
        h.run("target add su.ffg.happ")
        XCTAssertEqual(h.run("target remove Happ"), ExitCode.success)
        XCTAssertEqual(h.output.lines.last, "Цель снята: Happ")
        XCTAssertTrue(reopened().targets.isEmpty)
    }

    func test_an_ambiguous_name_asks_for_the_entry() {
        let names = ["a": "claude", "b": "claude", "c": "codex"]
        XCTAssertEqual(CLI.targetToRemove("claude", targets: ["a", "b", "c"], displayName: { names[$0] ?? $0 }),
                       .ambiguous(["a", "b"]))
        XCTAssertEqual(CLI.targetToRemove("b", targets: ["a", "b", "c"], displayName: { names[$0] ?? $0 }),
                       .found("b"), "запись важнее имени")
        XCTAssertEqual(CLI.targetToRemove("codex", targets: ["a", "b", "c"], displayName: { names[$0] ?? $0 }),
                       .found("c"))
    }

    func test_removing_an_unknown_target_fails() {
        XCTAssertEqual(h.run("target remove claude"), ExitCode.failure)
        XCTAssertEqual(h.output.errors.last, "такой цели нет в списке")
    }

    // MARK: - VPN

    func test_a_tunnel_replaces_the_app_and_the_app_replaces_the_tunnel() {
        h.run("vpn set su.ffg.happ")
        XCTAssertEqual(h.run("vpn set utun6"), ExitCode.success)
        XCTAssertEqual(reopened().vpnTunnel, "utun6")
        XCTAssertNil(reopened().vpnAppRule)
        XCTAssertTrue(h.output.lines.contains("VPN-приложение su.ffg.happ снято: VPN задаётся одним способом"))
        XCTAssertTrue(h.output.errors.isEmpty, "интерфейс поднят — предупреждать не о чем")

        h.run("vpn set su.ffg.happ")
        XCTAssertNil(reopened().vpnTunnel)
        XCTAssertEqual(reopened().vpnAppRule, "su.ffg.happ")
        XCTAssertTrue(h.output.lines.contains("VPN-туннель utun6 снят: VPN задаётся одним способом"))
    }

    /// wg0 может быть опущен в момент настройки — это не ошибка, но молчать нельзя.
    func test_a_missing_tunnel_is_saved_with_a_warning() {
        XCTAssertEqual(h.run("vpn set wg0"), ExitCode.success)
        XCTAssertEqual(reopened().vpnTunnel, "wg0")
        XCTAssertEqual(h.output.lines, ["VPN-туннель: wg0 — не поднят"])
        XCTAssertEqual(h.output.errors, [
            "интерфейса wg0 сейчас нет — пока он не поднимется, охрана считает туннель упавшим и завершает цели",
        ])
    }

    /// Правило `vpn set` — одно на обе платформы; порядок шагов и есть правило.
    func test_vpn_set_tells_an_app_from_a_tunnel_by_the_shared_rule() {
        let interfaces = ["en0", "utun6", "wg0"]
        let resolves: (String) -> Bool = { ["claude", "su.ffg.happ", "wg1"].contains($0) }
        let kind = { (value: String, hint: VPNKindHint) in
            CLI.vpnKind(of: value, hint: hint, interfaces: interfaces, resolves: resolves)
        }
        // 1. Флаг решает сам — даже против остальных правил.
        XCTAssertEqual(kind("claude", .tunnel), .tunnel)
        XCTAssertEqual(kind("wg0", .app), .app)
        // 2. Путь или бандл — приложение, даже если такое имя есть среди интерфейсов.
        XCTAssertEqual(kind("/Applications/Happ.app", .automatic), .app)
        XCTAssertEqual(kind("./wg0", .automatic), .app)
        XCTAssertEqual(kind("Happ.app", .automatic), .app)
        // 3. Существующий интерфейс (wg0 здесь опущен, но есть) — туннель.
        XCTAssertEqual(kind("wg0", .automatic), .tunnel)
        // 4. Разрешилось как цель — приложение, раньше допустимого имени интерфейса.
        XCTAssertEqual(kind("su.ffg.happ", .automatic), .app)
        XCTAssertEqual(kind("wg1", .automatic), .app)
        // 5. Допустимое имя интерфейса, которого нет, — туннель.
        XCTAssertEqual(kind("tun0", .automatic), .tunnel)
        // 6. Ни то, ни другое.
        XCTAssertNil(kind("my vpn", .automatic))
        XCTAssertNil(kind("очень-длинное-имя", .automatic))
    }

    func test_vpn_set_names_what_it_chose() {
        h.lowered = ["wg0"]
        XCTAssertEqual(h.run("vpn set wg0"), ExitCode.success)
        XCTAssertEqual(h.output.lines.last, "VPN-туннель: wg0 — не поднят")

        XCTAssertEqual(h.run("vpn set utun6"), ExitCode.success)
        XCTAssertEqual(h.output.lines.last, "VPN-туннель: utun6 — несёт трафик")

        XCTAssertEqual(h.run("vpn set su.ffg.happ"), ExitCode.success)
        XCTAssertEqual(Array(h.output.lines.suffix(2)), [
            "VPN-приложение: Happ (/Applications/Happ.app)",
            "VPN-туннель utun6 снят: VPN задаётся одним способом",
        ])
        XCTAssertEqual(reopened().vpnAppRule, "su.ffg.happ")
    }

    func test_vpn_set_of_nothing_known_fails_with_code_one() {
        XCTAssertEqual(h.cli.execute(.vpnSet("my vpn", .automatic)), ExitCode.failure)
        XCTAssertEqual(h.output.errors.last, "не найдено ни приложения, ни сетевого интерфейса с таким именем")
        XCTAssertNil(reopened().vpnTunnel)
        XCTAssertNil(reopened().vpnAppRule)
    }

    func test_tunnel_names_follow_the_interface_name_rules() {
        XCTAssertTrue(CLI.isValidTunnelName("wg0"))
        XCTAssertTrue(CLI.isValidTunnelName("tun-0.vpn_1"))
        XCTAssertTrue(CLI.isValidTunnelName(String(repeating: "a", count: 15)))
        XCTAssertFalse(CLI.isValidTunnelName(""))
        XCTAssertFalse(CLI.isValidTunnelName(String(repeating: "a", count: 16)))
        XCTAssertFalse(CLI.isValidTunnelName("wg 0"))
        XCTAssertFalse(CLI.isValidTunnelName("wg0;rm"))
        XCTAssertFalse(CLI.isValidTunnelName("туннель"))

        XCTAssertEqual(h.run("vpn set --tunnel wg/0"), ExitCode.usage)
        XCTAssertNil(reopened().vpnTunnel)
    }

    func test_vpn_show_names_what_is_chosen() {
        h.run("vpn show")
        XCTAssertEqual(h.output.lines.last, "VPN: не задан (охрана работает по гео одной)")

        h.run("vpn set utun6")
        h.run("vpn show")
        XCTAssertEqual(h.output.lines.last, "VPN-туннель: utun6 — несёт трафик")

        h.outgoing = OutgoingRoute(interface: "en0", address: "192.168.0.100")
        h.run("vpn show")
        XCTAssertEqual(h.output.lines.last, "VPN-туннель: utun6 — поднят, но трафик идёт мимо, через en0")

        h.run("vpn set su.ffg.happ")
        h.run("vpn show")
        XCTAssertEqual(h.output.lines.last, "VPN-приложение: Happ (/Applications/Happ.app)")

        XCTAssertEqual(h.run("vpn clear"), ExitCode.success)
        XCTAssertNil(reopened().vpnAppRule)
        XCTAssertNil(reopened().vpnTunnel)
    }

    func test_vpn_list_marks_the_carrier_and_the_choice() {
        h.run("vpn set utun6")
        h.run("vpn list")
        XCTAssertEqual(Array(h.output.lines.suffix(2)), [
            "  en0",
            "* utun6 — трафик наружу идёт здесь (198.18.0.1) [выбран]",
        ])

        h.outgoing = nil
        h.run("vpn list")
        XCTAssertEqual(h.output.lines.last, "Наружу трафик не выпускает никто")
    }

    // MARK: - Списки

    /// Тексты ошибок ввода — те же, что в окне настроек.
    func test_geo_lists_take_the_window_path_and_its_errors() {
        XCTAssertEqual(h.run("blacklist add ru"), ExitCode.success)
        XCTAssertEqual(h.output.lines.last, "Добавлено: RU")
        XCTAssertEqual(h.run("blacklist add 198.51.100.0/24"), ExitCode.success)
        XCTAssertEqual(reopened().blockedEntries, ["RU", "198.51.100.0/24"])

        XCTAssertEqual(h.run("blacklist add RU"), ExitCode.failure)
        XCTAssertEqual(h.output.errors.last, GeoListEntryError.duplicate.displayText)
        XCTAssertEqual(h.run("whitelist add nonsense"), ExitCode.usage)
        XCTAssertEqual(h.output.errors.last, GeoListEntryError.invalidEntry.displayText)

        h.run("blacklist list")
        XCTAssertEqual(Array(h.output.lines.suffix(2)), ["RU", "198.51.100.0/24"])

        XCTAssertEqual(h.run("blacklist remove ru"), ExitCode.success)
        XCTAssertEqual(h.run("blacklist remove 198.51.100.0/24"), ExitCode.success)
        XCTAssertTrue(reopened().blockedEntries.isEmpty)
        XCTAssertEqual(h.run("whitelist remove NL"), ExitCode.failure)

        h.run("whitelist list")
        XCTAssertEqual(h.output.lines.last, "Список пуст")
    }

    // MARK: - Таймаут и токен

    func test_timeout_is_shown_and_set_in_minutes() {
        h.run("timeout show")
        XCTAssertEqual(h.output.lines.last, "Подтверждение ждётся 1 мин")
        XCTAssertEqual(h.run("timeout set 5"), ExitCode.success)
        XCTAssertEqual(reopened().pauseCeiling, .fiveMinutes)
        XCTAssertEqual(h.output.lines.last, "Подтверждение ждётся 5 мин")
    }

    func test_token_is_stored_in_a_private_file_and_never_printed() throws {
        XCTAssertEqual(h.run("token set s3cret"), ExitCode.success)
        XCTAssertEqual(reopened().ipinfoToken, "s3cret")
        let attributes = try FileManager.default.attributesOfItem(atPath: h.paths.tokenFile.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        h.run("token show")
        XCTAssertEqual(h.output.lines.last, "Токен ipinfo: задан")
        XCTAssertFalse((h.output.lines + h.output.errors).contains { $0.contains("s3cret") })

        XCTAssertEqual(h.run("token clear"), ExitCode.success)
        XCTAssertEqual(reopened().ipinfoToken, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.paths.tokenFile.path))
        h.run("token show")
        XCTAssertEqual(h.output.lines.last, "Токен ipinfo: не задан")
    }

    func test_token_set_without_an_argument_reads_stdin() {
        h.stdinLine = "  fromstdin\n"
        XCTAssertEqual(h.run("token set"), ExitCode.success)
        XCTAssertEqual(reopened().ipinfoToken, "fromstdin")

        h.stdinLine = ""
        XCTAssertEqual(h.run("token set"), ExitCode.usage)
        h.stdinLine = nil
        XCTAssertEqual(h.run("token set"), ExitCode.usage)
        XCTAssertEqual(reopened().ipinfoToken, "fromstdin")
    }

    // MARK: - Журнал

    func test_journal_prints_the_newest_records_first() {
        h.run("journal")
        XCTAssertEqual(h.output.lines.last, "Журнал пуст")

        let store = EventLogStore(storage: JournalFile(directory: h.paths.dataDirectory)!)
        let episode = UUID()
        store.record([
            KillEvent(episodeID: episode, date: Date(timeIntervalSince1970: 1_800_000_000), targetName: "claude",
                      pid: 4120, kind: .terminated, reasonText: "VPN-туннель wg0 не поднят", ip: nil, country: nil),
        ])
        store.record([
            KillEvent(episodeID: UUID(), date: Date(timeIntervalSince1970: 1_800_000_100), targetName: "codex",
                      pid: 4133, parentPID: 4120, matchedBy: .descendant, kind: .paused,
                      reasonText: "Подтверждающие сервисы недоступны", resolutionText: "возобновлено проверкой",
                      ip: nil, country: nil),
        ])

        let lines = CLI.journalLines(JournalEpisode.group(store.events)[0], timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(lines, [
            "15.01.2027 08:01:40  codex  на паузе — подтверждающие сервисы недоступны",
            "    Итог: возобновлено проверкой",
        ])

        h.run("journal")
        XCTAssertFalse(h.output.lines.contains { $0.contains("pid") }, "строка на эпизод, pid не нужен")
        let codex = h.output.lines.firstIndex { $0.contains("codex") } ?? .max
        let claude = h.output.lines.firstIndex { $0.contains("claude") } ?? .min
        XCTAssertLessThan(codex, claude, "свежие записи первыми")
    }

    func test_journal_json_is_the_shared_export() throws {
        h.run("target add claude")
        XCTAssertEqual(h.run("journal --json"), ExitCode.success)
        let json = try XCTUnwrap(h.output.lines.last)
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let settings = object?["settings"] as? [String: Any]
        XCTAssertEqual(settings?["targets"] as? [String], ["claude"])
        XCTAssertNotNil(object?["events"])
        XCTAssertFalse(json.contains("token\":\""), "токен в выгрузку не попадает никогда")
    }

    // MARK: - Статус

    private func writeStatus(pid: Int32, updatedAgo: TimeInterval, lastProbeAt: Date? = nil) throws {
        let status = GuardStatus(
            pid: pid, updatedAt: h.now.addingTimeInterval(-updatedAgo), lastProbeAt: lastProbeAt,
            phase: .init(kind: "protected", title: "На страже", action: "цели работают", evidence: "—"),
            pauseDeadline: nil,
            reading: .init(ip: "203.0.113.28", country: "KZ", confirmedCountry: "KZ", confirmSource: "freeipapi"),
            outgoing: .init(interface: "utun6", address: "198.18.0.1"),
            vpn: .init(kind: "tunnel", name: "utun6", status: "carrying", via: nil),
            targets: [.init(name: "claude", entry: "claude", running: [4120], paused: [])],
            pauseCeilingSeconds: 60
        )
        try status.write(to: h.paths.statusFile)
    }

    func test_status_without_a_file_says_the_guard_is_not_running() {
        h.run("target add claude")
        XCTAssertEqual(h.run("status"), ExitCode.notRunning)
        XCTAssertTrue(h.output.lines.contains(StatusText.notRunning))
        XCTAssertTrue(h.output.lines.contains("Цели:     claude"))
        XCTAssertTrue(h.output.lines.contains("Токен:    не задан"))
    }

    func test_status_of_a_stale_file_is_not_running() throws {
        h.guardProcess.alive = [4100]
        try writeStatus(pid: 4100, updatedAgo: 11)
        XCTAssertEqual(h.run("status"), ExitCode.notRunning)
    }

    func test_status_of_a_dead_pid_is_not_running() throws {
        try writeStatus(pid: 4100, updatedAgo: 1)
        XCTAssertEqual(h.run("status"), ExitCode.notRunning)
        XCTAssertEqual(h.run("status --json"), ExitCode.notRunning)
    }

    func test_status_of_a_live_guard_is_printed() throws {
        h.guardProcess.alive = [4100]
        try writeStatus(pid: 4100, updatedAgo: 1)
        XCTAssertEqual(h.run("status"), ExitCode.success)
        XCTAssertEqual(h.output.lines.first, "Охрана:   На страже — цели работают")
        XCTAssertTrue(h.output.lines.contains("VPN:      туннель utun6 — несёт трафик"))

        XCTAssertEqual(h.run("status --json"), ExitCode.success)
        let decoded = try GuardStatus.decode(Data(h.output.lines.last!.utf8))
        XCTAssertEqual(decoded.pid, 4100)
    }

    // MARK: - Проверка

    /// Охрана не запущена — одна проба в своём процессе, сигналов никому, выход 3.
    func test_check_without_a_guard_probes_here_and_signals_nobody() {
        h.run("target add claude")
        h.run("blacklist add RU")
        XCTAssertEqual(h.run("check"), ExitCode.notRunning)
        XCTAssertTrue(h.guardProcess.checksRequested.isEmpty)
        XCTAssertEqual(Array(h.output.lines.suffix(6)), [
            StatusText.notRunning,
            "Проверка в этом процессе — цели не трогаются:",
            "Вердикт:  выход безопасен — цели работали бы",
            "Выход:    203.0.113.28 · KZ, подтверждено freeipapi: KZ",
            "Трафик:   utun6 (198.18.0.1)",
            "VPN:      не задан (охрана работает по гео одной)",
        ])
    }

    func test_check_without_a_guard_applies_the_tunnel_first() {
        h.run("target add claude")
        h.run("vpn set --tunnel wg0")
        h.run("check")
        XCTAssertTrue(h.output.lines.contains("Вердикт:  VPN-туннель wg0 не поднят — работающая охрана завершила бы цели"))
        XCTAssertEqual(h.output.lines.last, "VPN:      туннель wg0 — не поднят")
    }

    /// Охрана жива — ей уходит сигнал, а ответ читается из её статуса.
    func test_check_with_a_live_guard_waits_for_a_new_probe() throws {
        h.guardProcess.alive = [4100]
        try writeStatus(pid: 4100, updatedAgo: 1, lastProbeAt: h.now.addingTimeInterval(-5))

        // Охрана «ответила» раньше, чем команда заглянула в файл.
        let answered = h.now
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated {
                try? self.writeStatus(pid: 4100, updatedAgo: 0, lastProbeAt: answered)
            }
        }
        XCTAssertEqual(h.run("check"), ExitCode.success)
        XCTAssertEqual(h.guardProcess.checksRequested, [4100])
        XCTAssertEqual(h.output.lines.last, "Таймаут:  подтверждение ждётся 1 мин")
    }

    func test_check_with_a_silent_guard_gives_up() throws {
        h.guardProcess.alive = [4100]
        try writeStatus(pid: 4100, updatedAgo: 1, lastProbeAt: h.now.addingTimeInterval(-5))
        XCTAssertEqual(h.run("check"), ExitCode.failure)
        XCTAssertTrue(h.output.errors.last?.hasPrefix("ответа проверки не дождался") ?? false)
        XCTAssertEqual(h.output.lines.first, "Охрана:   На страже — цели работают", "печатается последний статус")
    }
}
