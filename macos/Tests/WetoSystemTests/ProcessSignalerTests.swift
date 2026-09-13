import XCTest
import Darwin
@testable import WetoSystem
import WetoCore

/// Записывает вызовы сеймовой `sendToKernel`, чтобы `test_signals_are_sent_in_list_order`
/// мог проверить порядок, в котором `ProcessSignaler` реально дошёл до ядра, а не только
/// порядок результатов. `@unchecked Sendable` — вызовы происходят синхронно, в теле одного
/// теста, конкурентного доступа здесь нет.
private final class CallRecorder: @unchecked Sendable {
    private(set) var calls: [(pid: Int32, signal: Int32)] = []

    func record(_ pid: Int32, _ signal: Int32) {
        calls.append((pid, signal))
    }

    func reset() {
        calls.removeAll()
    }
}

final class ProcessSignalerTests: XCTestCase {

    private func spawnSleep() throws -> Process {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sleep")
        task.arguments = ["30"]
        try task.run()
        return task
    }

    private func snapshot(of pid: Int32) -> ProcessSnapshot? {
        ProcessRegistry().allProcesses().first { $0.pid == pid }
    }

    /// SIGSTOP виден реестру как остановленность, SIGCONT её снимает, SIGKILL завершает.
    func test_stop_resume_and_kill_are_visible_to_the_registry() throws {
        let task = try spawnSleep()
        defer {
            if task.isRunning {
                // Провалившийся ассерт мог оставить процесс в SSTOP: там SIGTERM
                // ложится в очередь ожидающих и не завершает его. SIGCONT — сначала.
                kill(task.processIdentifier, SIGCONT)
                task.terminate()
            }
        }
        let pid = task.processIdentifier
        let signaler = ProcessSignaler()

        XCTAssertEqual(snapshot(of: pid)?.isStopped, false)

        XCTAssertTrue(signaler.send(.stop, to: [pid]).allSatisfy(\.isDelivered))
        // Ядру нужно мгновение, чтобы перевести процесс в SSTOP.
        usleep(50_000)
        XCTAssertEqual(snapshot(of: pid)?.isStopped, true)

        XCTAssertTrue(signaler.send(.resume, to: [pid]).allSatisfy(\.isDelivered))
        usleep(50_000)
        XCTAssertEqual(snapshot(of: pid)?.isStopped, false)

        XCTAssertTrue(signaler.send(.kill, to: [pid]).allSatisfy(\.isDelivered))
        task.waitUntilExit()
        XCTAssertNil(snapshot(of: pid))
    }

    /// Процесс, умерший до сигнала, — не ошибка: журнал пишет каждого, но ESRCH доставкой считается.
    func test_missing_process_counts_as_delivered() {
        let results = ProcessSignaler().send(.stop, to: [Int32.max - 7])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.errorCode, ESRCH)
        XCTAssertTrue(results.first?.isDelivered == true)
    }

    /// Порядок — часть контракта: шелл раньше цели на стопе, цель раньше шелла на продолжении.
    ///
    /// `results.map(\.pid)` совпал бы со входным списком при любой реализации, которая
    /// возвращает по результату на pid, — даже при параллельной отправке, отправке в обратном
    /// порядке или групповом сигнале с последующей пересборкой массива по pid: `SignalResult`
    /// всегда несёт тот pid, для которого он посчитан, порядок самих результатов ничего
    /// не говорит о порядке, в котором сигналы дошли до ядра. Поэтому здесь подменяется сама
    /// точка вызова `kill(2)` (`ProcessSignaler(sendToKernel:)`) и фиксируется порядок
    /// фактических вызовов — без реальных процессов, они здесь не нужны.
    func test_signals_are_sent_in_list_order() {
        let recorder = CallRecorder()
        let signaler = ProcessSignaler(sendToKernel: { pid, signal in
            recorder.record(pid, signal)
            return 0
        })

        let stopResults = signaler.send(.stop, to: [222, 111])
        XCTAssertEqual(recorder.calls.map(\.pid), [222, 111])
        XCTAssertEqual(recorder.calls.map(\.signal), [SIGSTOP, SIGSTOP])
        XCTAssertTrue(stopResults.allSatisfy(\.isDelivered))

        recorder.reset()
        let resumeResults = signaler.send(.resume, to: [111, 222])
        XCTAssertEqual(recorder.calls.map(\.pid), [111, 222])
        XCTAssertEqual(recorder.calls.map(\.signal), [SIGCONT, SIGCONT])
        XCTAssertTrue(resumeResults.allSatisfy(\.isDelivered))
    }

    /// `Foundation.Process` делает потомка лидером собственной группы (`pgid == pid`),
    /// а не наследником группы раннера: сверять надо с тем, что говорит само ядро
    /// про этот pid, а не гадать по группе родителя.
    func test_registry_reports_the_process_group() throws {
        let task = try spawnSleep()
        defer { task.terminate() }
        let pid = task.processIdentifier
        let snapshot = try XCTUnwrap(snapshot(of: pid))
        XCTAssertEqual(snapshot.processGroup, getpgid(pid))
    }

    /// `>= 0` было тавтологией для `Int32` — верной и при баге, вечно оставляющем поле нулём.
    /// Сверяем с независимым источником: `tcgetpgrp` на управляющем терминале самого раннера
    /// (спавненный `sleep` не отделяется от терминала и наследует тот же tty). Если раннер
    /// не привязан к терминалу вовсе (CI без tty) — у потомка тоже не может быть управляющего
    /// терминала, и это отдельная, но тоже содержательная проверка.
    func test_registry_reports_the_terminal_foreground_group() throws {
        let task = try spawnSleep()
        defer { task.terminate() }
        let pid = task.processIdentifier
        let snapshot = try XCTUnwrap(snapshot(of: pid))

        guard let terminalPath = ttyname(STDIN_FILENO) else {
            XCTAssertEqual(snapshot.terminalForegroundGroup, 0)
            return
        }

        let terminalFD = open(terminalPath, O_RDONLY | O_NOCTTY)
        guard terminalFD >= 0 else {
            throw XCTSkip("Не удалось открыть \(terminalPath) для независимой проверки tcgetpgrp.")
        }
        defer { close(terminalFD) }

        let kernelForegroundGroup = tcgetpgrp(terminalFD)
        guard kernelForegroundGroup >= 0 else {
            throw XCTSkip("tcgetpgrp вернул ошибку — не с чем сверять e_tpgid в этом окружении.")
        }

        XCTAssertEqual(snapshot.terminalForegroundGroup, kernelForegroundGroup)
    }
}
