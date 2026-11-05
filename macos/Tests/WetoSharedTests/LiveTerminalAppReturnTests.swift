import XCTest
import Darwin
@testable import WetoShared
import WetoCore
import WetoSystem

/// Живая проверка в настоящих iTerm2 и Terminal.app, без tmux: цель, оставшаяся в фоне, строка
/// шелла забита отчётами мыши, потому что цель включила их отслеживание и не может выключить.
/// Открывает своё окно и закрывает его в конце.
///
/// Запускается руками, в CI этих приложений нет:
/// `WETO_LIVE_APP=iterm swift test --filter LiveTerminalAppReturnTests` (или `terminal`).
/// С настоящей программой: `WETO_LIVE_TARGET=$HOME/.local/bin/claude` в придачу.
@MainActor
final class LiveTerminalAppReturnTests: XCTestCase {

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

    private func osa(_ script: String) -> String {
        let path = NSTemporaryDirectory() + "wetolive-\(UUID().uuidString).applescript"
        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        return sh("/usr/bin/osascript \(path)")
    }

    /// Окно одного из приложений: как его открыть, что в него ввести, что на экране.
    private struct Window {
        let tty: String
        let type: (String) -> Void
        let typeWithoutEnter: (String) -> Void
        let screen: () -> String
        let close: () -> Void
    }

    private func iTermWindow() -> Window {
        // Профиль по умолчанию может открывать `tmux -CC`, а здесь проверяется путь без tmux.
        // Закрытое приложение своего словаря AppleScript не отдаёт.
        sh("open -a /Applications/iTerm.app")
        Thread.sleep(forTimeInterval: 2)
        let id = osa("""
        tell application "iTerm2"
            set w to (create window with default profile command "/bin/zsh -il")
            return id of w
        end tell
        """)
        let session = "current session of current tab of window id \(id)"
        let say: (String, Bool) -> Void = { text, enter in
            let quoted = text.replacingOccurrences(of: "\"", with: "\\\"")
            _ = self.osa("""
            tell application "iTerm2" to tell \(session) to write text "\(quoted)" newline \(enter ? "YES" : "NO")
            """)
        }
        Thread.sleep(forTimeInterval: 1.5)
        return Window(
            tty: osa("tell application \"iTerm2\" to return tty of \(session)"),
            type: { say($0, true) },
            typeWithoutEnter: { say($0, false) },
            screen: { self.osa("tell application \"iTerm2\" to return contents of \(session)") },
            close: { _ = self.osa("tell application \"iTerm2\" to close window id \(id)") }
        )
    }

    private func terminalWindow() -> Window {
        let tty = osa("""
        tell application "Terminal"
            set t to do script ""
            delay 1.5
            return tty of t
        end tell
        """)
        // Вкладка ищется по tty: так же, как это делает охрана.
        let inTab: (String) -> String = { body in
            self.osa("""
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            \(body)
                        end if
                    end repeat
                end repeat
            end tell
            """)
        }
        let say: (String) -> Void = { text in
            let quoted = text.replacingOccurrences(of: "\"", with: "\\\"")
            _ = inTab("do script \"\(quoted)\" in t")
        }
        return Window(
            tty: tty,
            type: say,
            // У `do script` без Enter не бывает. `print -z` кладёт текст в строку следующего приглашения.
            typeWithoutEnter: { say("print -z '\($0)'") },
            screen: { inTab("return history of t") },
            close: { _ = inTab("close w saving no") }
        )
    }

    func test_a_target_in_the_background_returns_through_a_line_full_of_mouse_reports() throws {
        let app = ProcessInfo.processInfo.environment["WETO_LIVE_APP"]
        try XCTSkipUnless(app == "iterm" || app == "terminal")

        let raw = NSTemporaryDirectory() + "wetolive-\(UUID().uuidString.prefix(8))"
        sh("mkdir -p \(raw)")
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
            printf("\\033[?1003h\\033[?1006h"); fflush(stdout);
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
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path
        let window = app == "iterm" ? iTermWindow() : terminalWindow()
        defer { window.close() }
        XCTAssertTrue(window.tty.hasPrefix("/dev/"), window.tty)

        window.type("cd '\(live == nil ? dir : repository)' && \(live ?? "\(probe) \(out)")")
        func isRaw() -> Bool { sh("stty -a -f \(window.tty)").contains("-icanon") }
        for _ in 0..<150 where !isRaw() { Thread.sleep(forTimeInterval: 0.1) }
        Thread.sleep(forTimeInterval: live == nil ? 0.3 : 4)

        let suite = "com.weto.liveapp.\(UUID().uuidString)"
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
        // процессы этого окна.
        var info = stat()
        XCTAssertEqual(stat(window.tty, &info), 0)
        let full = enforcer.scan()
        let scan = ProcessEnforcer.Scan(
            processes: full.processes.filter { $0.terminalDevice == info.st_rdev },
            rules: full.rules
        )
        let rawMode = try TerminalModeKeeper().capture(device: info.st_rdev).get()
        let paused = enforcer.pause(scan)
        XCTAssertEqual(paused.plan.foregroundRoots.count, 1, "цель держала терминал")
        let root = try XCTUnwrap(paused.plan.foregroundRoots.first)

        // Мышь двигается и под паузой: отчёты копятся в очереди терминала.
        let report = "\u{1B}[<35;173;10M"
        if app == "iterm" { window.typeWithoutEnter(report) }
        Thread.sleep(forTimeInterval: 1.5)

        for _ in 0..<3 {
            enforcer.resume(observing: enforcer.scan())
            enforcer.restoreTerminalModes(observing: enforcer.scan())
            Thread.sleep(forTimeInterval: 0.3)
        }
        let chain = ProcessTree(processes: locator.allProcesses(includeArguments: false)).ancestors(of: root)
            .prefix(4).map { pid in
                sh("ps -o comm= -p \(pid)").split(separator: "/").last.map(String.init) ?? "?"
            }
        let afterResume = enforcer.awaitingForeground()
        print("[live] родители цели: \(chain); после снятия паузы ждёт возврата: \(!afterResume.isEmpty)")

        // Без мультиплексора порядок сигналов обычно держит цель впереди. Призрак воспроизводим
        // сами: тот же стоп только цели, без шелла, — шелл забирает терминал.
        if afterResume.isEmpty {
            kill(root, SIGSTOP)
            Thread.sleep(forTimeInterval: 0.7)
            kill(root, SIGCONT)
            Thread.sleep(forTimeInterval: 0.5)
            print("[live] призрак воспроизведён вручную: \(sh("ps -o tpgid=,pgid=,stat= -p \(root)"))")
        }

        // Строка шелла забита отчётами мыши, и точки с запятой в них — разделители команд.
        let junk = app == "iterm"
            ? String(repeating: report, count: 12)
            : String(repeating: "35;173;10M", count: 12)
        window.typeWithoutEnter(junk)
        Thread.sleep(forTimeInterval: 0.6)

        let processes = locator.allProcesses(includeArguments: false)
        let target = try XCTUnwrap(processes.first { $0.pid == root })
        let shell = try XCTUnwrap(PausePlanner.shellHoldingTerminal(of: target, among: processes),
                                  "терминал обязан быть у шелла")
        let result = TerminalForegroundReturner()
            .returnToForeground(target: target, shell: shell, processes: processes, usingAutomation: true)
        XCTAssertTrue(result.isSuccess, "\(result)")
        Thread.sleep(forTimeInterval: 0.8)
        // Режим на этой дорожке охрана уже вернула при снятии паузы, а шелл его сменил: возвращаем сами.
        _ = TerminalModeKeeper().restore(rawMode)

        let screen = window.screen()
        XCTAssertFalse(screen.contains("command not found"), "строка выполнилась как команды:\n\(screen)")
        let now = locator.allProcesses(includeArguments: false)
        let returned = try XCTUnwrap(now.first { $0.pid == root })
        XCTAssertTrue(PausePlanner.holdsForeground(returned, among: now), "цель обязана быть впереди:\n\(screen)")
        XCTAssertTrue(isRaw(), "терминал обязан быть в сыром режиме цели")

        if live == nil {
            window.typeWithoutEnter("x")
            Thread.sleep(forTimeInterval: 0.7)
            if app == "iterm" {
                XCTAssertTrue(sh("cat \(out)").contains("got:x"), "клавиша обязана дойти до цели")
            }
        }
        print("[live] экран:\n\(screen.split(separator: "\n").suffix(6).joined(separator: "\n"))")
        kill(root, SIGKILL)
    }
}
