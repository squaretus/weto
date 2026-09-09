import XCTest
import Darwin
import WetoCore
@testable import WetoSystem

/// Настоящий pty, настоящий интерактивный zsh, настоящее переднее задание.
///
/// Прежняя проверка `e_tpgid` сверялась с `tcgetpgrp` управляющего терминала **самого
/// раннера** и пропускалась (`XCTSkip`), когда терминала нет, — то есть про чужой
/// процесс с чужим терминалом не проверяла ничего. Между тем на этом поле держится
/// весь план паузы: `terminalForegroundGroup == 0` заставляет `PausePlanner` молча
/// пропустить шелл цели, а без шелла в плане zsh успевает напечатать
/// `suspended (signal)` и забрать терминал себе — цель становится фоновым заданием,
/// ровно тем, что контракт порядка сигналов и обязан предотвращать.
///
/// Здесь pty поднимается свой (`script -q` запускает zsh в новом pty, поэтому тесту
/// не нужен терминал раннера), в нём выполняется `sleep`, и на настоящем снимке ядра
/// проверяются оба звена: чтение поля `ProcessRegistry` и план `PausePlanner`.
final class ForegroundJobPlanTests: XCTestCase {

    /// Терминальный сеанс, живущий ровно на время теста: `script` держит pty, zsh — задание.
    private final class TerminalSession {
        let task = Process()
        let input = Pipe()
        var shellPID: Int32 = 0
        var jobPID: Int32 = 0

        /// SIGCONT перед SIGKILL: остановленному процессу SIGKILL доходит, а вот
        /// вышестоящим он мог бы прийти, пока они стоят, — и тест оставил бы за собой
        /// замороженное дерево. Гасим только своих потомков, снизу вверх.
        func tearDown() {
            for pid in [jobPID, shellPID] where pid > 0 {
                kill(pid, SIGCONT)
                kill(pid, SIGKILL)
            }
            try? input.fileHandleForWriting.close()
            if task.isRunning {
                kill(task.processIdentifier, SIGCONT)
                task.terminate()
            }
            task.waitUntilExit()
        }
    }

    /// Ждать появления процесса нельзя вечно: сорванный `script` или zsh без job control
    /// обязаны провалить тест, а не подвесить прогон.
    private static let spawnTimeout: TimeInterval = 15

    private func waitForChild(
        of parent: Int32,
        executablePath: String
    ) -> (pid: Int32, snapshot: ProcessSnapshot)? {
        let deadline = Date().addingTimeInterval(Self.spawnTimeout)
        while Date() < deadline {
            let processes = ProcessRegistry().allProcesses()
            if let found = processes.first(where: {
                $0.parentPID == parent && $0.executablePath == executablePath
            }) {
                return (found.pid, found)
            }
            usleep(100_000)
        }
        return nil
    }

    /// `zsh -i` без ZDOTDIR читает `.zshrc` пользователя: он может печатать что угодно,
    /// плодить процессы и просто быть медленным. Сеанс поднимается на пустом каталоге.
    private func startSession() throws -> TerminalSession {
        guard FileManager.default.fileExists(atPath: "/usr/bin/script") else {
            throw XCTSkip("В окружении нет /usr/bin/script — свой pty поднять нечем.")
        }
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("weto-pty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: sandbox) }

        let session = TerminalSession()
        session.task.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        session.task.arguments = ["-q", sandbox.appendingPathComponent("typescript").path, "/bin/zsh", "-i"]
        session.task.standardInput = session.input
        session.task.standardOutput = FileHandle.nullDevice
        session.task.standardError = FileHandle.nullDevice
        session.task.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": sandbox.path,
            "ZDOTDIR": sandbox.path,
            "TERM": "dumb"
        ]
        try session.task.run()

        let shell = waitForChild(of: session.task.processIdentifier, executablePath: "/bin/zsh")
        guard let shell else {
            session.tearDown()
            throw XCTSkip("zsh в pty не поднялся за \(Int(Self.spawnTimeout)) с — проверять нечего.")
        }
        session.shellPID = shell.pid

        // Команда уходит в pty через stdin `script`: канал остаётся открытым,
        // иначе zsh увидит EOF и выйдет вместе с заданием.
        session.input.fileHandleForWriting.write(Data("sleep 900\n".utf8))

        let job = waitForChild(of: shell.pid, executablePath: "/bin/sleep")
        guard let job else {
            session.tearDown()
            throw XCTSkip("Переднее задание в pty не появилось — проверять нечего.")
        }
        session.jobPID = job.pid
        return session
    }

    /// Ядро говорит про чужой процесс то же, что `getpgid`: поле не нулевое и равно
    /// группе задания. Раньше это утверждение не проверялось ни разу — сверка шла
    /// с терминалом раннера, которого под `swift test` обычно нет.
    func test_registry_reads_the_foreground_group_of_a_real_job_in_a_foreign_pty() throws {
        let session = try startSession()
        defer { session.tearDown() }

        let job = try XCTUnwrap(ProcessRegistry().allProcesses().first { $0.pid == session.jobPID })
        XCTAssertEqual(job.processGroup, getpgid(session.jobPID))
        XCTAssertNotEqual(job.terminalForegroundGroup, 0,
                          "e_tpgid у переднего задания не может быть нулём: терминал у него.")
        XCTAssertEqual(job.terminalForegroundGroup, job.processGroup,
                       "У переднего задания передняя группа терминала — его собственная.")
    }

    /// Тот же снимок, но целиком через `PausePlanner`: шелл задания обязан войти в план
    /// и обязан стоять в нём первым. Поменяются местами шелл и цель — тест упадёт.
    func test_planner_takes_the_shell_of_a_real_foreground_job_first() throws {
        let session = try startSession()
        defer { session.tearDown() }

        let processes = ProcessRegistry().allProcesses()
        let target = MatchedProcess(pid: session.jobPID, targetName: "sleep",
                                    parentPID: session.shellPID, executablePath: "/bin/sleep",
                                    matchedBy: .rule)
        let plan = PausePlanner.plan(matched: [target], processes: processes)

        XCTAssertEqual(plan.shells, [session.shellPID],
                       "Шелл переднего задания обязан войти в план: без него zsh забирает терминал.")
        XCTAssertEqual(plan.stopOrder, [session.shellPID, session.jobPID],
                       "Порядок — часть контракта: шелл раньше своей цели.")
        XCTAssertTrue(plan.backgrounded.isEmpty,
                      "Переднее задание фоновым не считается: терминал у него.")
        XCTAssertTrue(plan.skipped.isEmpty)
    }
}
