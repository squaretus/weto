import XCTest
import Darwin
@testable import WetoShared
import WetoCore
import WetoSystem

/// Живая проверка на настоящем tmux: настоящие обход, сигналы, режим терминала и ввод `fg`.
/// Под tmux шелл панели забирает терминал у стоящей цели, и SIGCONT оставляет её в фоне:
/// интерфейс нарисован, а клавиши идут шеллу. Моки этого не покажут.
///
/// Запускается руками, в CI tmux нет:
/// `WETO_LIVE_TMUX=1 swift test --filter LiveTmuxReturnTests`
/// С настоящей программой: `WETO_LIVE_TARGET=$HOME/.local/bin/claude` в придачу. Она стартует
/// в корне репозитория: в новой папке claude остановился бы на вопросе о доверии, и рабочей
/// сессии тест бы не увидел. Никакого запроса она не отправляет: текст набирается без Enter.
@MainActor
final class LiveTmuxReturnTests: XCTestCase {

    @discardableResult
    private func sh(_ command: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func test_a_paused_target_comes_back_with_the_keyboard() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WETO_LIVE_TMUX"] == "1")

        let raw = NSTemporaryDirectory() + "wetolive-\(UUID().uuidString.prefix(8))"
        sh("mkdir -p \(raw)/work")
        let dir = sh("cd \(raw) && pwd -P")
        let out = dir + "/probe.out"
        let probe = dir + "/rawprobe"
        let source = """
        #include <stdio.h>
        #include <termios.h>
        #include <unistd.h>
        #include <sys/select.h>
        int main(int c, char **v) {
            FILE *o = fopen(v[1], "a"); setvbuf(o, NULL, _IONBF, 0);
            struct termios t; tcgetattr(0, &t); cfmakeraw(&t); tcsetattr(0, TCSANOW, &t);
            printf("\\033[>4;2m"); fflush(stdout);
            for (;;) {
                fd_set r; FD_ZERO(&r); FD_SET(0, &r);
                struct timeval tv = {0, 200000};
                if (select(1, &r, NULL, NULL, &tv) > 0) {
                    char b[64]; ssize_t n = read(0, b, sizeof b);
                    if (n > 0) { fprintf(o, "got:%.*s\\n", (int)n, b); }
                }
            }
        }
        """
        try source.write(toFile: dir + "/rawprobe.c", atomically: true, encoding: .utf8)
        XCTAssertEqual(sh("cc -o \(probe) \(dir)/rawprobe.c"), "")

        let live = ProcessInfo.processInfo.environment["WETO_LIVE_TARGET"]
        let server = "wetolive\(getpid())"
        let tmux = "tmux -L \(server) -f /dev/null"
        sh("\(tmux) new-session -d -x 120 -y 30")
        // Так настроен tmux у живых пользователей, и программа вроде `claude` включает расширенные
        // клавиши, а из фона выключить их не может: `send-keys C-u` приходит в шелл как
        // `ESC[27;5;117~`, и строку это не стирает.
        sh("\(tmux) set -s extended-keys on; \(tmux) set -s extended-keys-format xterm")
        defer { sh("\(tmux) kill-server") }
        Thread.sleep(forTimeInterval: 1.5)
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path
        let workingDirectory = live == nil ? "\(dir)/work" : "'\(repository)'"
        sh("\(tmux) send-keys \"cd \(workingDirectory) && \(live ?? "\(probe) \(out)")\" Enter")

        let paneTTY = sh("\(tmux) display -p '#{pane_tty}'")
        func isRaw() -> Bool { sh("stty -a -f \(paneTTY)").contains("-icanon") }
        for _ in 0..<150 where !isRaw() { Thread.sleep(forTimeInterval: 0.1) }
        Thread.sleep(forTimeInterval: live == nil ? 0.2 : 4)

        let suite = "com.weto.livetmux.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        settings.targets = [live ?? probe]
        let locator = ProcessRegistry()
        let enforcer = ProcessEnforcer(
            settings: settings, resolver: TargetResolver(), locator: locator, signaler: ProcessSignaler(),
            ledger: StoppedLedger(storage: InMemoryStoppedLedger()), terminalModes: TerminalModeKeeper()
        )

        // Правило совпадает со всеми такими процессами на машине, а останавливать можно только
        // процессы панели теста: рядом может работать настоящая сессия пользователя.
        var paneInfo = stat()
        XCTAssertEqual(stat(paneTTY, &paneInfo), 0)
        let full = enforcer.scan()
        let scan = ProcessEnforcer.Scan(
            processes: full.processes.filter { $0.terminalDevice == paneInfo.st_rdev },
            rules: full.rules
        )

        let paused = enforcer.pause(scan)
        XCTAssertEqual(paused.plan.foregroundRoots.count, 1, "цель держала терминал")
        Thread.sleep(forTimeInterval: 1)

        for _ in 0..<3 {
            enforcer.resume(observing: enforcer.scan())
            enforcer.restoreTerminalModes(observing: enforcer.scan())
            Thread.sleep(forTimeInterval: 0.3)
        }

        // Ровно тот призрак: цель идёт, терминал у шелла.
        let waiting = enforcer.awaitingForeground()
        let target = try XCTUnwrap(waiting.first, "цель обязана ждать возврата")

        // Набранное в строке шелла не должно склеиться с `fg`. Цель включила отслеживание мыши
        // и выключить его не может, поэтому в строку без конца идут отчёты, в том числе между
        // любыми двумя нашими командами. Точки с запятой в них — разделители команд.
        sh("\(tmux) send-keys 'half typed'")
        let mouse = Process()
        mouse.executableURL = URL(fileURLWithPath: "/bin/bash")
        mouse.arguments = ["-c", "while :; do \(tmux) send-keys -l $'\\e[<35;173;10M'; done"]
        try mouse.run()
        defer { mouse.terminate() }
        Thread.sleep(forTimeInterval: 0.5)

        let processes = locator.allProcesses(includeArguments: false)
        let shell = try XCTUnwrap(PausePlanner.shellHoldingTerminal(of: target, among: processes))
        let result = TerminalForegroundReturner(allowsAutomation: false)
            .returnToForeground(target: target, shell: shell, processes: processes, usingAutomation: false)
        XCTAssertTrue(result.isSuccess, "\(result)")

        Thread.sleep(forTimeInterval: 0.3)
        enforcer.restoreTerminalModes()
        mouse.terminate()
        mouse.waitUntilExit()

        let screen = sh("\(tmux) capture-pane -p")
        XCTAssertFalse(screen.contains("command not found"), "строка выполнилась как команды:\n\(screen)")
        XCTAssertTrue(enforcer.awaitingForeground().isEmpty, "цель снова впереди, режим возвращён:\n\(screen)")
        XCTAssertTrue(isRaw(), "терминал обязан быть в сыром режиме цели")

        if live == nil {
            sh("\(tmux) send-keys x")
            Thread.sleep(forTimeInterval: 0.7)
            XCTAssertTrue(sh("cat \(out)").contains("got:x"), "клавиша обязана дойти до цели")
        } else {
            // Призрак тоже рисует интерфейс, но набранное до него не доходит.
            let marker = "wetolivemarker"
            sh("\(tmux) send-keys -l \(marker)")
            Thread.sleep(forTimeInterval: 2)
            let pane = sh("\(tmux) capture-pane -p")
            print("[live] state: \(sh("ps -o stat= -p \(target.pid)"))")
            XCTAssertFalse(pane.contains("trust this folder"), "сессия не дошла до работы:\n\(pane)")
            XCTAssertTrue(pane.contains(marker), "набранное обязано дойти до цели:\n\(pane)")
            XCTAssertFalse(pane.contains("command not found"), "клавиши ушли шеллу:\n\(pane)")
            XCTAssertFalse(sh("ps -o stat= -p \(target.pid)").hasPrefix("T"), "цель обязана идти")
        }
        print("[live] pane:\n\(sh("\(tmux) capture-pane -p | grep -v '^$' | tail -6"))")
    }
}
