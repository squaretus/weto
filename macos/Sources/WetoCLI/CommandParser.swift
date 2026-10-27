import Foundation
import WetoCore
import WetoShared

/// Как `vpn set` понимает значение: само или по явному флагу.
enum VPNKindHint: Equatable {
    /// Без флага: приложение или туннель определяется по правилу из ТЗ.
    case automatic
    case app
    case tunnel
}

/// Объект команды — первое слово грамматики `weto <объект> <действие> [значение]`.
enum CommandObject: String, CaseIterable, Equatable {
    case target, vpn, blacklist, whitelist, timeout, token, service, update
}

/// Команда терминальной версии. Набор и написание общие с Linux.
enum Command: Equatable {
    case help
    /// Справка по одному объекту: `weto vpn help`, `weto help vpn`.
    case objectHelp(CommandObject)
    case version
    case run
    case status(json: Bool)
    case check
    case journal(json: Bool)
    case targetList
    case targetAdd(String)
    case targetRemove(String)
    case vpnShow
    case vpnSet(String, VPNKindHint)
    case vpnClear
    case vpnList
    case geoList(GeoListKind)
    case geoAdd(GeoListKind, String)
    case geoRemove(GeoListKind, String)
    case timeoutShow
    case timeoutSet(PauseCeiling)
    /// `nil` — токен читается из stdin: в истории шелла ему не место.
    case tokenSet(String?)
    case tokenClear
    case tokenShow
    case serviceInstall
    case serviceUninstall
    case serviceStatus
    case updateCheck
    case updateInstall

    /// Работает ли команда у обычного пользователя на машине с охраной от root.
    /// Остальные получают подсказку про sudo: настройки, журналы и токен системной
    /// установки принадлежат root, его процессу не пошлёшь сигнал проверки, а своя
    /// охрана или свой сервис рядом с системными дрались бы с ними за те же цели.
    var worksBesideSystemInstall: Bool {
        switch self {
        case .help, .objectHelp, .version, .status, .updateCheck, .serviceStatus:
            return true
        default:
            return false
        }
    }
}

extension Command {

    /// Команда так, как её набрать заново, — для подсказки «sudo weto …». Токен
    /// в подсказку не попадает никогда: она печатается на экран и уходит в логи.
    var invocation: String {
        switch self {
        case .help: return "help"
        case .objectHelp(let object): return "\(object.rawValue) help"
        case .version: return "version"
        case .run: return "run"
        case .status(let json): return json ? "status --json" : "status"
        case .check: return "check"
        case .journal(let json): return json ? "journal --json" : "journal"
        case .targetList: return "target list"
        case .targetAdd(let value): return "target add \(Self.quoted(value))"
        case .targetRemove(let value): return "target remove \(Self.quoted(value))"
        case .vpnShow: return "vpn show"
        case .vpnSet(let value, let hint):
            let flag: String
            switch hint {
            case .automatic: flag = ""
            case .app: flag = "--app "
            case .tunnel: flag = "--tunnel "
            }
            return "vpn set \(flag)\(Self.quoted(value))"
        case .vpnClear: return "vpn clear"
        case .vpnList: return "vpn list"
        case .geoList(let kind): return "\(Self.listName(kind)) list"
        case .geoAdd(let kind, let value): return "\(Self.listName(kind)) add \(Self.quoted(value))"
        case .geoRemove(let kind, let value): return "\(Self.listName(kind)) remove \(Self.quoted(value))"
        case .timeoutShow: return "timeout show"
        case .timeoutSet(let ceiling): return "timeout set \(ceiling.rawValue / 60)"
        case .tokenSet: return "token set"
        case .tokenClear: return "token clear"
        case .tokenShow: return "token show"
        case .serviceInstall: return "service install"
        case .serviceUninstall: return "service uninstall"
        case .serviceStatus: return "service status"
        case .updateCheck: return "update check"
        case .updateInstall: return "update"
        }
    }

    private static func listName(_ kind: GeoListKind) -> String {
        kind == .blocked ? "blacklist" : "whitelist"
    }

    /// Слово с пробелом или знаком шелла — в одинарных кавычках, чтобы подсказку
    /// можно было скопировать и выполнить.
    private static func quoted(_ value: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-/:@+,=")
        guard !value.isEmpty, !value.unicodeScalars.allSatisfy(plain.contains) else { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension Command {

    /// Команда root, после которой на машине есть охрана от root: правка настроек,
    /// сама охрана, сервис. Её след — системный каталог данных, по нему обычный
    /// пользователь узнаёт о системной установке. Чтение, справка и `sudo weto update`
    /// следа не оставляют: иначе пользователь со своей установкой, обновивший
    /// бинарник через sudo, оказался бы отрезан от собственного хранилища.
    var marksSystemInstall: Bool {
        switch self {
        case .run, .serviceInstall, .targetAdd, .targetRemove, .vpnSet, .vpnClear, .geoAdd, .geoRemove,
             .timeoutSet, .tokenSet, .tokenClear:
            return true
        default:
            return false
        }
    }
}

/// Неверные аргументы: код выхода `2`, текст — что именно не так.
struct UsageError: Error, Equatable {
    let message: String
}

/// Коды выхода — общие с Linux.
enum ExitCode {
    static let success: Int32 = 0
    static let failure: Int32 = 1
    static let usage: Int32 = 2
    /// Охрана не запущена — для `status` и `check`.
    static let notRunning: Int32 = 3
}

/// Разбор аргументов — свой, без внешних зависимостей: их в проекте нет.
enum CommandParser {

    static func parse(_ arguments: [String]) -> Result<Command, UsageError> {
        guard let head = arguments.first else {
            // Без единого аргумента — сообщение и полная справка, обе в stderr.
            return .failure(UsageError(message: "команда не указана\n" + helpText(version: version)))
        }
        let rest = Array(arguments.dropFirst())

        guard let object = CommandObject(rawValue: head) else {
            return command(head, rest).mapError { error in
                error == extraMarker
                    ? UsageError(message: "неверные аргументы команды «\(head)»: weto help")
                    : error
            }
        }
        return parse(object, rest).mapError { error in
            error == extraMarker
                ? UsageError(message: "неверные аргументы команды «\(head)»\n" + objectHelp(object))
                : error
        }
    }

    /// Команды без объекта: охрана, справка, версия.
    private static func command(_ head: String, _ rest: [String]) -> Result<Command, UsageError> {
        switch head {
        case "help", "--help", "-h":
            guard let topic = rest.first else { return .success(.help) }
            guard rest.count == 1, let object = CommandObject(rawValue: topic) else { return .failure(extraMarker) }
            return .success(.objectHelp(object))
        case "version", "--version":
            return none(rest, .version)
        case "run":
            return none(rest, .run)
        case "status":
            return jsonFlag(rest).map { .status(json: $0) }
        case "check":
            return none(rest, .check)
        case "journal":
            return jsonFlag(rest).map { .journal(json: $0) }
        default:
            return .failure(UsageError(message: "неизвестная команда «\(head)»: weto help"))
        }
    }

    private static func parse(_ object: CommandObject, _ rest: [String]) -> Result<Command, UsageError> {
        // `weto update` без действия — установка: так её и зовут чаще всего.
        if object == .update, rest.isEmpty { return .success(.updateInstall) }
        // Объект без действия — справка по нему в stderr, код 2.
        guard let action = rest.first else { return .failure(UsageError(message: objectHelp(object))) }
        if ["help", "--help", "-h"].contains(action) { return none(Array(rest.dropFirst()), .objectHelp(object)) }
        let tail = Array(rest.dropFirst())

        let parsed: Result<Command, UsageError>?
        switch object {
        case .target: parsed = target(action, tail)
        case .vpn: parsed = vpn(action, tail)
        case .blacklist: parsed = geoList(action, tail, kind: .blocked)
        case .whitelist: parsed = geoList(action, tail, kind: .allowed)
        case .timeout: parsed = timeout(action, tail)
        case .token: parsed = token(action, tail)
        case .service: parsed = service(action, tail)
        case .update: parsed = update(action, tail)
        }
        return parsed ?? .failure(UsageError(
            message: "неизвестное действие «\(action)» у \(object.rawValue)\n" + objectHelp(object)
        ))
    }

    /// Лишние слова. Текст зависит от того, чья это команда, — его подставляет `parse`.
    private static let extraMarker = UsageError(message: "\u{0}лишние аргументы")

    private static func none(_ rest: [String], _ command: Command) -> Result<Command, UsageError> {
        guard rest.isEmpty else { return .failure(extraMarker) }
        return .success(command)
    }

    private static func jsonFlag(_ rest: [String]) -> Result<Bool, UsageError> {
        switch rest {
        case []: return .success(false)
        case ["--json"]: return .success(true)
        default: return .failure(extraMarker)
        }
    }

    /// Ровно один аргумент: путь с пробелами приходит одним словом в кавычках,
    /// и склеивать слова за пользователя значило бы угадывать.
    private static func single(_ rest: [String], what: String) -> Result<String, UsageError> {
        guard let value = rest.first else { return .failure(UsageError(message: "не указано: \(what)")) }
        guard rest.count == 1 else { return .failure(extraMarker) }
        return .success(value)
    }

    private static func target(_ action: String, _ tail: [String]) -> Result<Command, UsageError>? {
        switch action {
        case "list": return none(tail, .targetList)
        case "add": return single(tail, what: "имя, путь или bundle id цели").map(Command.targetAdd)
        case "remove": return single(tail, what: "запись или имя цели").map(Command.targetRemove)
        default: return nil
        }
    }

    private static func vpn(_ action: String, _ tail: [String]) -> Result<Command, UsageError>? {
        switch action {
        case "show": return none(tail, .vpnShow)
        case "clear": return none(tail, .vpnClear)
        case "list": return none(tail, .vpnList)
        case "set":
            var hint = VPNKindHint.automatic
            var values = tail
            switch values.first {
            case "--app": hint = .app; values.removeFirst()
            case "--tunnel": hint = .tunnel; values.removeFirst()
            default: break
            }
            return single(values, what: "путь, имя или bundle id VPN-приложения либо имя интерфейса")
                .map { .vpnSet($0, hint) }
        default: return nil
        }
    }

    private static func geoList(_ action: String, _ tail: [String], kind: GeoListKind) -> Result<Command, UsageError>? {
        switch action {
        case "list": return none(tail, .geoList(kind))
        case "add": return single(tail, what: "страна, IP-адрес или CIDR").map { .geoAdd(kind, $0) }
        case "remove": return single(tail, what: "запись списка").map { .geoRemove(kind, $0) }
        default: return nil
        }
    }

    private static func timeout(_ action: String, _ tail: [String]) -> Result<Command, UsageError>? {
        switch action {
        case "show": return none(tail, .timeoutShow)
        case "set":
            return single(tail, what: "таймаут в минутах — 1, 2, 5 или 10").flatMap { value in
                guard let minutes = Int(value), let ceiling = PauseCeiling(rawValue: minutes * 60) else {
                    return .failure(UsageError(message: "таймаут — 1, 2, 5 или 10 минут"))
                }
                return .success(.timeoutSet(ceiling))
            }
        default: return nil
        }
    }

    private static func token(_ action: String, _ tail: [String]) -> Result<Command, UsageError>? {
        switch action {
        case "set":
            guard tail.count <= 1 else { return .failure(extraMarker) }
            return .success(.tokenSet(tail.first))
        case "clear": return none(tail, .tokenClear)
        case "show": return none(tail, .tokenShow)
        default: return nil
        }
    }

    private static func service(_ action: String, _ tail: [String]) -> Result<Command, UsageError>? {
        switch action {
        case "install": return none(tail, .serviceInstall)
        case "uninstall": return none(tail, .serviceUninstall)
        case "status": return none(tail, .serviceStatus)
        default: return nil
        }
    }

    private static func update(_ action: String, _ tail: [String]) -> Result<Command, UsageError>? {
        switch action {
        case "check": return none(tail, .updateCheck)
        case "install": return none(tail, .updateInstall)
        default: return nil
        }
    }

    // MARK: - Справка

    /// Строки справки по объекту — те же, что в общей справке, плюс заголовок.
    static func objectHelp(_ object: CommandObject) -> String {
        ([objectTitles[object] ?? "weto \(object.rawValue)"] + (objectLines[object] ?? []))
            .joined(separator: "\n")
    }

    private static let objectTitles: [CommandObject: String] = [
        .target: "weto target — цели: что охрана останавливает и завершает",
        .vpn: "weto vpn — VPN: приложение или туннель, одно из двух",
        .blacklist: "weto blacklist — чёрный список: страны, адреса и диапазоны, при которых цели завершаются",
        .whitelist: "weto whitelist — белый список: если не пуст, выход обязан в него попасть",
        .timeout: "weto timeout — сколько цели стоят на паузе в ожидании подтверждения",
        .token: "weto token — токен ipinfo",
        .service: "weto service — охрана сервисом launchd",
        .update: "weto update — обновление weto из релизов GitHub",
    ]

    private static let objectLines: [CommandObject: [String]] = [
        .target: [
            "  weto target list",
            "  weto target add <имя|путь|bundle id>",
            "  weto target remove <запись|имя>",
        ],
        .vpn: [
            "  weto vpn show                     что выбрано и в каком оно состоянии",
            "  weto vpn set [--app|--tunnel] <путь|имя|bundle id|интерфейс>",
            "                                    приложение или туннель определяется само; флаг задаёт явно",
            "  weto vpn clear                    снять выбор: охрана работает по гео одной",
            "  weto vpn list                     поднятые интерфейсы; отмечен тот, через который трафик идёт наружу",
        ],
        .blacklist: [
            "  weto blacklist list",
            "  weto blacklist add <страна|IP|CIDR>",
            "  weto blacklist remove <запись>",
        ],
        .whitelist: [
            "  weto whitelist list",
            "  weto whitelist add <страна|IP|CIDR>",
            "  weto whitelist remove <запись>",
        ],
        .timeout: [
            "  weto timeout show",
            "  weto timeout set <1|2|5|10>       в минутах",
        ],
        .token: [
            "  weto token show                   только «задан» / «не задан», сам токен не печатается",
            "  weto token set [<токен>]          без аргумента — читает строку из stdin (не светить токен в истории)",
            "  weto token clear",
        ],
        .service: [
            "  weto service install              от root — на всю машину (LaunchDaemon), иначе — для пользователя",
            "  weto service uninstall",
            "  weto service status",
        ],
        .update: [
            "  weto update check                 есть ли версия новее",
            "  weto update install               скачать, проверить сумму, заменить бинарник, перезапустить сервис",
            "  weto update                       то же, что install",
        ],
    ]

    /// Общая справка с версией последней строкой — канон раунда 3, общий с Linux;
    /// отличаются только запись цели и VPN (на macOS ещё и bundle id) и строки хранилища.
    static func helpText(version: String) -> String {
        helpBody + "\nВерсия: \(version)"
    }

    private static let helpBody = """
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
    """

    /// Имя, под которым `make-cli.sh` вшивает Info.plist в бинарник.
    static let bundleName = "weto"

    /// Версия: `make-cli.sh <версия>` вшивает Info.plist в бинарник; без него — `dev`.
    /// Имя сверяется намеренно: в тестах `Bundle.main` — раннер xctest со своей
    /// версией («16.0»), и она к нам не относится.
    static var version: String {
        let info = Bundle.main.infoDictionary
        guard info?["CFBundleName"] as? String == bundleName,
              let version = info?["CFBundleShortVersionString"] as? String
        else { return "dev" }
        return version
    }
}
