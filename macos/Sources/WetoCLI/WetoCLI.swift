import Foundation

/// Точка входа `weto`: терминальная версия weto поверх того же бэкенда охраны.
///
/// Главный цикл — `RunLoop.main`, а не `dispatchMain()`: источник событий сети
/// вешает `SCDynamicStore` на главный run loop, и без него смена сети была бы
/// видна только такту. Главная очередь, на которой живёт `@MainActor`, обслуживается
/// тем же циклом.
@main
struct WetoCLI {

    static func main() {
        let output = StandardOutput()
        let arguments = Array(CommandLine.arguments.dropFirst())

        let command: Command
        switch CommandParser.parse(arguments) {
        case .success(let parsed):
            command = parsed
        case .failure(let error):
            // Без единого аргумента сообщение уже несёт справку целиком, как у Linux.
            output.err(error.message)
            exit(ExitCode.usage)
        }

        let code: Int32? = MainActor.assumeIsolated {
            var env = CLIEnvironment.live(output: output)
            env.arguments = arguments
            guard command == .run else {
                return CLI(env: env).execute(command)
            }
            // Своя охрана рядом с охраной от root дралась бы с ней за те же цели.
            if let refusal = CLI.systemInstallRefusal(command, env: env) {
                output.err(refusal)
                return ExitCode.failure
            }
            env.paths.prepareSystemDirectory()
            let runner = GuardRunner(
                paths: env.paths, settings: env.settings, appDetector: env.appDetector,
                log: GuardLog(), output: output, updateSource: env.updateSource
            )
            Self.runner = runner
            return runner.start()
        }
        if let code { exit(code) }

        // Охрана стартовала: дальше работают такты, события сети и обработчики сигналов.
        // Выход — из обработчика SIGTERM/SIGINT.
        RunLoop.main.run()
    }

    /// Держит охрану живой до конца процесса.
    @MainActor private static var runner: GuardRunner?
}
