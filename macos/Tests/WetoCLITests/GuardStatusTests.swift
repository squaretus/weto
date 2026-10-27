import XCTest
@testable import WetoCLI
import WetoCore
import WetoShared

/// Файл статуса — общий формат с Linux: его читают `status` и `check`, а пишет
/// работающая охрана. Поля без ответа — `null`, а не пропуск.
@MainActor
final class GuardStatusTests: XCTestCase {

    private let moment = Date(timeIntervalSince1970: 1_793_008_800) // 2026-10-26T10:00:00Z
    private let reading = GeoReading(ip: "203.0.113.28", primaryCountry: "KZ", confirmedCountry: "KZ",
                                     confirmSource: .freeipapi)

    private func inputs(
        phase: GuardPhase,
        tunnel: String? = "wg0",
        tunnelStatus: VPNTunnelStatus = .carrying,
        paused: [PausedProcess] = [],
        deadline: Date? = nil
    ) -> GuardStatus.Inputs {
        GuardStatus.Inputs(
            pid: 4100, now: moment, phase: phase, lastReading: reading,
            lastProbeAt: moment.addingTimeInterval(-2), pauseDeadline: deadline,
            outgoing: OutgoingRoute(interface: "wg0", address: "10.8.0.2"),
            vpnAppRule: nil, vpnAppName: nil, vpnAppStatus: .notChosen,
            vpnTunnel: tunnel, vpnTunnelStatus: tunnelStatus,
            targets: [(entry: "claude", name: "claude"), (entry: "codex", name: "codex")],
            runningTargets: [
                RunningTarget(entry: "claude", displayName: "claude", kind: .binary, path: "/bin/claude",
                              pid: 4120, processCount: 3),
                RunningTarget(entry: "claude", displayName: "claude", kind: .binary, path: "/bin/claude",
                              pid: 4133, processCount: 1),
            ],
            pausedProcesses: paused,
            pauseCeiling: .oneMinute
        )
    }

    func test_the_file_carries_the_shared_shape_with_explicit_nulls() throws {
        var status = GuardStatus(inputs(phase: .protected(reading)))
        status.lastProbeAt = nil
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: status.encoded()) as? [String: Any])

        let target = try XCTUnwrap((object["targets"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(target.keys), ["name", "entry", "running", "paused", "backgrounded"])
        XCTAssertEqual(Set(object.keys), [
            "version", "pid", "updatedAt", "lastProbeAt", "phase", "pauseDeadline", "reading",
            "outgoing", "vpn", "targets", "pauseCeilingSeconds", "updateAvailable",
        ])
        XCTAssertTrue(object["updateAvailable"] is NSNull, "обновления нет — null, а не пропуск")
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["updatedAt"] as? String, "2026-10-26T10:00:00Z")
        XCTAssertTrue(object["lastProbeAt"] is NSNull, "поле без ответа — null, а не пропуск")
        XCTAssertTrue(object["pauseDeadline"] is NSNull)

        let phase = try XCTUnwrap(object["phase"] as? [String: Any])
        XCTAssertEqual(phase["kind"] as? String, "protected")
        XCTAssertEqual(phase["title"] as? String, "На страже")
        XCTAssertEqual(phase["action"] as? String, "цели работают")

        let vpn = try XCTUnwrap(object["vpn"] as? [String: Any])
        XCTAssertEqual(vpn["kind"] as? String, "tunnel")
        XCTAssertEqual(vpn["status"] as? String, "carrying")
        XCTAssertTrue(vpn["via"] is NSNull)

        let targets = try XCTUnwrap(object["targets"] as? [[String: Any]])
        XCTAssertEqual(targets.first?["running"] as? [Int], [4120, 4133])
        XCTAssertEqual(targets.last?["running"] as? [Int], [])
        XCTAssertEqual(object["pauseCeilingSeconds"] as? Int, 60)
    }

    func test_written_status_is_read_back() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("status.json")
        let status = GuardStatus(inputs(phase: .protected(reading)))

        try status.write(to: url)

        XCTAssertEqual(GuardStatus.read(from: url), status)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("tmp").path))
    }

    /// У системной охраны umask `077`, а статус обязан читаться без sudo.
    func test_the_status_file_is_readable_by_everyone_even_under_a_strict_umask() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("status.json")

        let previous = umask(0o077)
        defer { umask(previous) }
        try GuardStatus(inputs(phase: .protected(reading))).write(to: url)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o644)
    }

    /// Файл охраны прошлого раунда без `updateAvailable` читается как «обновления нет».
    func test_a_file_without_update_available_reads_as_none() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: GuardStatus(inputs(phase: .protected(reading))).encoded()
        ) as? [String: Any])
        object.removeValue(forKey: "updateAvailable")
        let decoded = try GuardStatus.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.updateAvailable)
    }

    /// Строка «Обновление:» — только когда есть что сказать.
    func test_an_available_update_adds_one_line_to_the_text() throws {
        var withUpdate = inputs(phase: .protected(reading))
        withUpdate.updateAvailable = "0.3.0"
        let status = GuardStatus(withUpdate)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: status.encoded()) as? [String: Any])
        XCTAssertEqual(object["updateAvailable"] as? String, "0.3.0")

        XCTAssertEqual(StatusText.render(status, now: moment).last,
                       "Обновление: доступна версия 0.3.0 — sudo weto update")
        XCTAssertFalse(StatusText.render(GuardStatus(inputs(phase: .protected(reading))), now: moment)
            .contains { $0.hasPrefix("Обновление") })
    }

    /// «Не запущена» — по возрасту файла и по pid: упавшая охрана оставляет файл на месте.
    func test_liveness_needs_a_fresh_file_and_a_live_pid() {
        let status = GuardStatus(inputs(phase: .protected(reading)))
        let alive: (Int32) -> Bool = { $0 == 4100 }

        XCTAssertTrue(status.isLive(at: moment.addingTimeInterval(10), isAlive: alive))
        XCTAssertFalse(status.isLive(at: moment.addingTimeInterval(10.5), isAlive: alive), "файл устарел")
        XCTAssertFalse(status.isLive(at: moment.addingTimeInterval(1), isAlive: { _ in false }), "процесса нет")
    }

    func test_tunnel_and_app_and_none_are_reported_by_kind() {
        XCTAssertEqual(GuardStatus(inputs(phase: .protected(reading), tunnelStatus: .bypassed(via: "eth0"))).vpn,
                       GuardStatus.VPN(kind: "tunnel", name: "wg0", status: "bypassed", via: "eth0"))
        XCTAssertEqual(GuardStatus(inputs(phase: .protected(reading), tunnelStatus: .down)).vpn.status, "down")

        var app = inputs(phase: .protected(reading), tunnel: nil, tunnelStatus: .notChosen)
        app.vpnAppRule = "su.ffg.happ"
        app.vpnAppStatus = .notRunning
        XCTAssertEqual(GuardStatus(app).vpn, GuardStatus.VPN(kind: "app", name: "su.ffg.happ", status: "notRunning", via: nil))

        let none = GuardStatus(inputs(phase: .protected(reading), tunnel: nil, tunnelStatus: .notChosen))
        XCTAssertEqual(none.vpn, GuardStatus.VPN(kind: "none", name: nil, status: "notChosen", via: nil))
    }

    /// Локальная улика про выход не говорит ничего — прежний адрес в статус не едет.
    func test_local_evidence_hides_the_previous_exit() {
        let status = GuardStatus(inputs(phase: .danger(.vpnTunnelDown("wg0")), tunnelStatus: .down))
        XCTAssertNil(status.reading)
        XCTAssertEqual(status.phase, .init(kind: "danger", title: "Небезопасно", action: "цели завершены",
                                           evidence: "VPN-туннель wg0 не поднят"))
    }

    func test_paused_targets_and_the_deadline_reach_the_file_and_the_text() {
        let since = moment.addingTimeInterval(-17)
        let paused = [PausedProcess(pid: 4120, targetName: "claude", since: since, isBackgrounded: true)]
        let status = GuardStatus(inputs(
            phase: .paused(since: since, reason: .confirmationUnavailable),
            paused: paused, deadline: moment.addingTimeInterval(43)
        ))

        XCTAssertEqual(status.targets.first?.paused, [4120])
        XCTAssertEqual(status.targets.first?.running, [4133], "стоящие в «запущено» не входят")
        XCTAssertEqual(status.targets.first?.backgrounded, [4120])
        XCTAssertEqual(status.phase.kind, "paused")

        let lines = StatusText.render(status, now: moment)
        XCTAssertEqual(lines, [
            "Охрана:   Выход не подтверждён — цели остановлены",
            "Причина:  Подтверждающие сервисы недоступны",
            "Пауза:    43 с до завершения; возобновятся при подтверждении безопасного выхода",
            "Выход:    203.0.113.28 · KZ, подтверждено freeipapi: KZ",
            "Трафик:   wg0 (10.8.0.2)",
            "VPN:      туннель wg0 — несёт трафик",
            "Цели:     claude — на паузе (pid 4120)",
            "            pid 4120: процесс вернулся в фон. Откройте терминал и введите fg",
            "          codex — не запущено",
            "Таймаут:  подтверждение ждётся 1 мин",
        ])
    }

    func test_the_protected_text_matches_the_contract() {
        let lines = StatusText.render(GuardStatus(inputs(phase: .protected(reading))), now: moment)
        XCTAssertEqual(lines, [
            "Охрана:   На страже — цели работают",
            "Выход:    203.0.113.28 · KZ, подтверждено freeipapi: KZ",
            "Трафик:   wg0 (10.8.0.2)",
            "VPN:      туннель wg0 — несёт трафик",
            "Цели:     claude — запущено 2 (pid 4120, 4133)",
            "          codex — не запущено",
            "Таймаут:  подтверждение ждётся 1 мин",
        ])
    }
}
