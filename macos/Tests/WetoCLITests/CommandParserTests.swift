import XCTest
@testable import WetoCLI
import WetoCore

/// Разбор аргументов — свой, без зависимостей, и общий по написанию с Linux:
/// одна и та же строка обязана значить одно и то же на обеих платформах.
final class CommandParserTests: XCTestCase {

    private func parsed(_ line: String) -> Command? {
        try? CommandParser.parse(line.split(separator: " ").map(String.init)).get()
    }

    private func usage(_ arguments: [String]) -> String? {
        guard case .failure(let error) = CommandParser.parse(arguments) else { return nil }
        return error.message
    }

    func test_every_command_of_the_contract_is_understood() {
        let cases: [(String, Command)] = [
            ("help", .help), ("--help", .help), ("-h", .help),
            ("version", .version),
            ("run", .run),
            ("status", .status(json: false)), ("status --json", .status(json: true)),
            ("check", .check),
            ("journal", .journal(json: false)), ("journal --json", .journal(json: true)),
            ("target list", .targetList),
            ("target add claude", .targetAdd("claude")),
            ("target remove claude", .targetRemove("claude")),
            ("vpn show", .vpnShow),
            ("vpn set su.ffg.happ", .vpnSet("su.ffg.happ", .automatic)),
            ("vpn set --app Happ", .vpnSet("Happ", .app)),
            ("vpn set --tunnel wg0", .vpnSet("wg0", .tunnel)),
            ("vpn clear", .vpnClear),
            ("vpn list", .vpnList),
            ("blacklist list", .geoList(.blocked)),
            ("blacklist add RU", .geoAdd(.blocked, "RU")),
            ("blacklist remove RU", .geoRemove(.blocked, "RU")),
            ("whitelist list", .geoList(.allowed)),
            ("whitelist add 198.51.100.0/24", .geoAdd(.allowed, "198.51.100.0/24")),
            ("whitelist remove NL", .geoRemove(.allowed, "NL")),
            ("timeout show", .timeoutShow),
            ("timeout set 1", .timeoutSet(.oneMinute)),
            ("timeout set 2", .timeoutSet(.twoMinutes)),
            ("timeout set 5", .timeoutSet(.fiveMinutes)),
            ("timeout set 10", .timeoutSet(.tenMinutes)),
            ("token show", .tokenShow),
            ("token set", .tokenSet(nil)),
            ("token set abc", .tokenSet("abc")),
            ("token clear", .tokenClear),
            ("service install", .serviceInstall),
            ("service uninstall", .serviceUninstall),
            ("service status", .serviceStatus),
            ("update check", .updateCheck),
            ("update install", .updateInstall),
            // Без действия `update` — установка.
            ("update", .updateInstall),
            ("vpn help", .objectHelp(.vpn)),
            ("help timeout", .objectHelp(.timeout)),
        ]
        for (line, expected) in cases {
            XCTAssertEqual(parsed(line), expected, line)
        }
    }

    /// Раунд 2 убрал прежние формы — они больше ничего не значат.
    func test_the_round_one_forms_are_gone() {
        for line in ["vpn app su.ffg.happ", "vpn tunnel wg0", "vpn tunnels", "timeout 5", "timeout"] {
            XCTAssertNil(parsed(line), line)
        }
    }

    /// Путь с пробелом приходит одним аргументом — так его и сохраняем.
    func test_a_path_with_spaces_stays_one_argument() {
        XCTAssertEqual(try CommandParser.parse(["target", "add", "/Applications/My Tool.app"]).get(),
                       .targetAdd("/Applications/My Tool.app"))
        XCTAssertEqual(try CommandParser.parse(["vpn", "set", "--app", "/Applications/My VPN.app"]).get(),
                       .vpnSet("/Applications/My VPN.app", .app))
    }

    /// Объект без действия — справка по нему, и это неверные аргументы (код 2).
    func test_an_object_without_an_action_is_its_help() {
        for object in [CommandObject.target, .vpn, .blacklist, .whitelist, .timeout, .token, .service] {
            XCTAssertEqual(usage([object.rawValue]), CommandParser.objectHelp(object), object.rawValue)
        }
        XCTAssertTrue(CommandParser.objectHelp(.vpn).hasPrefix("weto vpn — "))
        XCTAssertEqual(usage(["vpn", "tunnels"]), "неизвестное действие «tunnels» у vpn\n" + CommandParser.objectHelp(.vpn))
    }

    /// Тексты ошибок разбора — канон раунда 3, общий с Linux.
    func test_wrong_arguments_are_usage_errors() {
        XCTAssertEqual(usage([]), "команда не указана\n" + CommandParser.helpText(version: "dev"))
        XCTAssertEqual(usage(["bogus"]), "неизвестная команда «bogus»: weto help")
        for head in ["run", "status", "check", "journal", "version", "help"] {
            XCTAssertEqual(usage([head, "now"]), "неверные аргументы команды «\(head)»: weto help", head)
        }
        XCTAssertEqual(usage(["status", "--yaml"]), "неверные аргументы команды «status»: weto help")
        XCTAssertEqual(usage(["--version", "x"]), "неверные аргументы команды «--version»: weto help")
        XCTAssertEqual(usage(["target", "remove"]), "не указано: запись или имя цели")
        XCTAssertEqual(usage(["vpn", "set", "--tunnel"]),
                       "не указано: путь, имя или bundle id VPN-приложения либо имя интерфейса")
        XCTAssertEqual(usage(["timeout", "set"]), "не указано: таймаут в минутах — 1, 2, 5 или 10")
        XCTAssertEqual(usage(["blacklist", "add"]), "не указано: страна, IP-адрес или CIDR")
        XCTAssertEqual(usage(["whitelist", "add"]), "не указано: страна, IP-адрес или CIDR")
        XCTAssertEqual(usage(["timeout", "set", "3"]), "таймаут — 1, 2, 5 или 10 минут")
        XCTAssertEqual(usage(["timeout", "set", "abc"]), "таймаут — 1, 2, 5 или 10 минут")
        XCTAssertEqual(usage(["service", "restart"]),
                       "неизвестное действие «restart» у service\n" + CommandParser.objectHelp(.service))
        XCTAssertEqual(usage(["update", "now"]),
                       "неизвестное действие «now» у update\n" + CommandParser.objectHelp(.update))
        // Лишние слова у действия объекта — как у Linux: команда и справка объекта.
        XCTAssertEqual(usage(["target", "add", "a", "b"]),
                       "неверные аргументы команды «target»\n" + CommandParser.objectHelp(.target))
        XCTAssertEqual(usage(["token", "set", "a", "b"]),
                       "неверные аргументы команды «token»\n" + CommandParser.objectHelp(.token))
    }

    func test_version_has_the_double_dash_synonym() {
        XCTAssertEqual(parsed("--version"), .version)
    }

    /// Полная справка — канон раунда 3 дословно (macOS-подстановки).
    func test_the_help_is_the_canon() {
        XCTAssertEqual(CommandParser.helpText(version: "0.3.0"), """
        weto — охрана целей по VPN из терминала

        Использование: weto <объект> <действие> [значение]

        Охрана:
          weto status [--json]              фаза, улика, выход, VPN, цели, таймаут, обновление
          weto check                        внеплановая проверка подключения
          weto run                          охрана на переднем плане (для сервиса и отладки)
          weto journal [--json]             последние 20 записей журнала завершений; --json — выгрузка в общем формате

        Настройки:
          weto target    list | add <имя|путь|bundle id> | remove <запись|имя>
          weto vpn       show | set [--app|--tunnel] <путь|имя|bundle id|интерфейс> | clear | list
          weto blacklist list | add <страна|IP|CIDR> | remove <запись>
          weto whitelist list | add <страна|IP|CIDR> | remove <запись>
          weto timeout   show | set <1|2|5|10>
          weto token     show | set [<токен>] | clear

        Установка:
          weto service   install | uninstall | status
          weto update    check | install    (weto update без действия = install)
          weto version
          weto help | --help | -h

        Справка по объекту: weto <объект> help.
        Коды выхода: 0 — успех, 1 — ошибка, 2 — неверные аргументы, 3 — охрана не запущена.
        От root охраняется вся машина: настройки — набор com.weto.cli процесса root,
        журналы, статус и токен — /Library/Application Support/weto/.
        Иначе — набор com.weto.cli пользователя и ~/Library/Application Support/weto-cli/.
        Версия: 0.3.0
        """)
    }

    /// Подсказка «sudo weto …» набирается заново, а токен в неё не попадает.
    func test_the_invocation_retypes_the_command_without_the_token() {
        XCTAssertEqual(Command.targetAdd("/Applications/My Tool.app").invocation, "target add '/Applications/My Tool.app'")
        XCTAssertEqual(Command.vpnSet("wg0", .tunnel).invocation, "vpn set --tunnel wg0")
        XCTAssertEqual(Command.timeoutSet(.fiveMinutes).invocation, "timeout set 5")
        XCTAssertEqual(Command.tokenSet("s3cret").invocation, "token set")
        XCTAssertEqual(Command.geoAdd(.allowed, "NL").invocation, "whitelist add NL")
    }

    func test_exit_codes_are_the_shared_ones() {
        XCTAssertEqual(ExitCode.success, 0)
        XCTAssertEqual(ExitCode.failure, 1)
        XCTAssertEqual(ExitCode.usage, 2)
        XCTAssertEqual(ExitCode.notRunning, 3)
    }
}
