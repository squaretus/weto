import Foundation
import WetoCore
import WetoShared
import WetoSystem

/// Всё, что команде нужно от мира. Границы системы приходят сюда, а не создаются
/// по месту: команды настроек проверяются тестом против временного набора
/// и временного каталога.
@MainActor
struct CLIEnvironment {
    /// Хранилище этого процесса: системное у root, пользовательское иначе.
    var paths: CLIPaths
    /// Где лежала бы системная установка. Обычный пользователь сверяется с ней:
    /// есть охрана от root — его собственное хранилище ни о чём не говорит.
    var systemPaths: CLIPaths = .system()
    var settings: SettingsStore
    var resolver: TargetResolving
    var interfaces: InterfaceListing
    var snapshotReader: NetworkSnapshotReading
    var service: ServiceControlling
    var guardProcess: GuardProcessSignaling
    var appDetector: WetoAppDetecting
    var output: CLIOutput
    /// Строка токена из stdin — для `token set` без аргумента.
    var readSecretLine: () -> String?
    var now: () -> Date
    var executablePath: () -> String?
    var uid: uid_t
    /// Аргументы как введены — для подсказки «sudo weto …». Пусто — команда пришла
    /// не из командной строки, и подсказка набирает её заново.
    var arguments: [String] = []
    /// Кто позвал `sudo` (`SUDO_UID`): `sudo weto update` у пользовательской установки
    /// обязан перезапустить его LaunchAgent, а не искать LaunchDaemon, которого нет.
    var sudoUID: uid_t? = nil
    /// `SUDO_USER` — под root голое имя цели, которого не видит root, ищется у него.
    var sudoUser: String? = nil
    /// `PATH` пользователя по имени — граница системы.
    var userPaths: UserSearchPathProviding = AccountSearchPaths()
    /// Версия этой сборки: `dev`, если `make-cli.sh` её не вшил.
    var version: String = CommandParser.version
    /// Обновление: запросы к GitHub, распаковка и замена бинарника — границы.
    var updateSource: UpdateSource
    var unpacker: ArchiveUnpacking = TarUnpacker()
    var replacer: ExecutableReplacing = FileExecutableReplacer()
    /// Разовая проба для `check`, когда охрана не запущена.
    var makeProbe: (SettingsStore) -> GeoProbing
    var locator: ProcessLocating
    /// Сколько ждать ответа охраны на `check` и как часто заглядывать в статус.
    var checkTimeout: TimeInterval = 15
    var checkPollInterval: TimeInterval = 0.2
    /// Сколько разовая команда ждёт, пока станет известен носитель трафика.
    var snapshotSettleTimeout: TimeInterval = 3

    /// Набор настроек и токен CLI. Тот же `SettingsStore`, что у приложения,
    /// но со своими доменом и каталогом.
    static func settings(paths: CLIPaths) -> SettingsStore {
        SettingsStore(
            defaults: UserDefaults(suiteName: CLIPaths.suiteName) ?? .standard,
            secrets: FileSecretStore(directory: paths.dataDirectory)
        )
    }

    /// Хранилище выбирает эффективный uid, а не `$HOME`: `sudo` сохраняет `HOME`
    /// пользователя, и по нему root писал бы в чужой каталог.
    static func live(output: CLIOutput) -> CLIEnvironment {
        let isRoot = geteuid() == 0
        let paths = isRoot ? CLIPaths.system() : CLIPaths.currentUser
        if isRoot {
            // Токен, журналы и учёт root пишет только для себя; статус и каталог
            // данных открываются явно — `status` читается без sudo.
            umask(0o077)
        }
        return CLIEnvironment(
            paths: paths,
            settings: settings(paths: paths),
            resolver: TargetResolver(),
            interfaces: KernelInterfaceList(),
            snapshotReader: NetworkSnapshotReader(),
            service: Launchctl(),
            guardProcess: KernelGuardProcess(),
            appDetector: WetoAppProcessDetector(locator: ProcessRegistry()),
            output: output,
            readSecretLine: SecretInput.readLine,
            now: Date.init,
            executablePath: { Bundle.main.executablePath },
            uid: getuid(),
            sudoUID: isRoot ? ProcessInfo.processInfo.environment["SUDO_UID"].flatMap { uid_t($0) } : nil,
            sudoUser: isRoot ? ProcessInfo.processInfo.environment["SUDO_USER"] : nil,
            updateSource: UpdateSource(
                fetcher: URLSessionHTTPFetcher(timeout: 60), currentVersion: CommandParser.version
            ),
            makeProbe: { settings in
                GeoProbe(
                    fetcher: URLSessionHTTPFetcher(),
                    confirmationFetcher: URLSessionHTTPFetcher(timeout: Constants.geoConfirmationTimeoutSeconds),
                    token: { [box = settings.tokenBox] in box.value }
                )
            },
            locator: ProcessRegistry()
        )
    }
}

/// Команды, кроме `run`: правки настроек, статус, проверка, журнал, сервис.
///
/// Правки идут теми же сеттерами `SettingsStore`, что правки из окна, — работающая
/// охрана перечитывает набор раз в секунду и применяет их сама.
@MainActor
final class CLI {

    let env: CLIEnvironment

    init(env: CLIEnvironment) {
        self.env = env
    }

    private var settings: SettingsStore { env.settings }

    private func out(_ line: String) { env.output.out(line) }
    private func err(_ line: String) { env.output.err(line) }

    /// Обычный пользователь на машине с охраной от root: всё, кроме статуса,
    /// справки и проверки обновлений, — через sudo. `nil` — команда идёт как есть.
    static func systemInstallRefusal(_ command: Command, env: CLIEnvironment) -> String? {
        guard !env.paths.isSystem, !command.worksBesideSystemInstall, env.systemPaths.isInstalled else { return nil }
        // Аргументы — как введены, по канону: подсказку копируют и добавляют sudo.
        // Исключение — токен: подсказка уходит на экран и в логи, а `sudo weto token set`
        // без значения прочитает его из stdin.
        if case .tokenSet = command { return systemInstallHint(command.invocation) }
        return systemInstallHint(env.arguments.isEmpty ? command.invocation : env.arguments.joined(separator: " "))
    }

    static func systemInstallHint(_ invocation: String) -> String {
        "охрана установлена на всю машину — sudo weto \(invocation)"
    }

    /// Пользователь, рядом с которым стоит охрана от root, смотрит на неё, а не на себя.
    private var besideSystemInstall: Bool { !env.paths.isSystem && env.systemPaths.isInstalled }

    func execute(_ command: Command) -> Int32 {
        if let refusal = Self.systemInstallRefusal(command, env: env) {
            err(refusal)
            return ExitCode.failure
        }
        if command.marksSystemInstall { env.paths.prepareSystemDirectory() }
        switch command {
        case .help:
            out(CommandParser.helpText(version: env.version))
            return ExitCode.success
        case .objectHelp(let object):
            out(CommandParser.objectHelp(object))
            return ExitCode.success
        case .version:
            out("weto \(env.version)")
            return ExitCode.success
        case .run:
            // `run` живёт своим циклом и сюда не попадает: его разбирает точка входа.
            err("run запускается точкой входа")
            return ExitCode.failure
        case .status(let json): return status(json: json)
        case .check: return check()
        case .targetList: return targetList()
        case .targetAdd(let text): return targetAdd(text)
        case .targetRemove(let text): return targetRemove(text)
        case .vpnShow: return vpnShow()
        case .vpnSet(let text, let hint): return vpnSet(text, hint)
        case .vpnList: return vpnList()
        case .vpnClear: return vpnClear()
        case .geoList(let kind): return geoList(kind)
        case .geoAdd(let kind, let text): return geoAdd(kind, text)
        case .geoRemove(let kind, let text): return geoRemove(kind, text)
        case .timeoutShow:
            out(Self.capitalized(StatusText.timeoutText(seconds: settings.pauseCeiling.rawValue)))
            return ExitCode.success
        case .timeoutSet(let ceiling):
            settings.pauseCeiling = ceiling
            out(Self.capitalized(StatusText.timeoutText(seconds: ceiling.rawValue)))
            return ExitCode.success
        case .tokenSet(let value): return tokenSet(value)
        case .tokenClear: return tokenClear()
        case .tokenShow:
            out("Токен ipinfo: \(settings.ipinfoToken.isEmpty ? "не задан" : "задан")")
            return ExitCode.success
        case .journal(let json): return journal(json: json)
        case .serviceInstall: return serviceInstall()
        case .serviceUninstall: return serviceUninstall()
        case .serviceStatus: return serviceStatus()
        case .updateCheck: return updateCheck()
        case .updateInstall: return updateInstall()
        }
    }

    // MARK: - Цели

    /// Запись цели в том виде, в каком её сохранило бы окно: путь к `.app`
    /// превращается в bundle id, как при выборе с диска; остальное — как введено.
    /// Что за записью стоит, решает охрана при каждом разрешении: путь у многих
    /// инструментов меняется с каждой версией.
    static func normalizedEntry(_ text: String) -> String {
        let entry = text.trimmingCharacters(in: .whitespaces)
        guard entry.hasSuffix(".app") || entry.hasSuffix(".app/"),
              FileManager.default.fileExists(atPath: entry),
              let identifier = Bundle(path: entry)?.bundleIdentifier
        else { return entry }
        return identifier
    }

    /// Во что запись разрешилась сейчас: «бинарник: /bin/sleep» или почему не нашлась.
    private func describe(_ entry: String) -> String {
        GuardVM.resolvedDescription(forTarget: entry, resolver: env.resolver)
    }

    private func displayName(_ entry: String) -> String {
        env.resolver.resolve(entry)?.displayName ?? entry
    }

    /// «Happ (/Applications/Happ.app)» — имя и путь, как в окне; не найдено — почему.
    private func appDescription(_ entry: String) -> String {
        guard let rule = env.resolver.resolve(entry) else {
            return "\(entry) (\(GuardVM.resolvedDescription(forTarget: entry, resolver: env.resolver)))"
        }
        return "\(rule.displayName) (\(rule.path))"
    }

    static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    private func targetList() -> Int32 {
        guard !settings.targets.isEmpty else {
            out("Цели не выбраны — охрана ничего не завершает")
            return ExitCode.success
        }
        // Как на Linux: имя и запись строкой, во что запись разрешилась — следующей.
        for entry in settings.targets {
            out("\(displayName(entry)) (\(entry))")
            out("  \(describe(entry))")
        }
        return ExitCode.success
    }

    /// Голое имя под `sudo`, которого не видит root, — у того, кто вызвал sudo:
    /// `sudo weto target add claude` при `claude` в его `~/.local/bin`. Только под root
    /// и только при `SUDO_USER`, отличном от root; путь, `.app`, bundle id и имя,
    /// найденное по `PATH` root, идут как раньше.
    private func foundForSudoCaller(_ entry: String) -> (user: String, path: String)? {
        guard env.paths.isSystem, let user = env.sudoUser, !user.isEmpty, user != "root",
              !entry.contains("/"), !entry.hasSuffix(".app"),
              env.resolver.resolve(entry) == nil,
              let path = UserExecutableSearch.find(entry, user: user, in: env.userPaths)
        else { return nil }
        return (user, path)
    }

    static func foundInUserPath(user: String, path: String) -> String {
        "найдено в PATH пользователя \(user): \(path)"
    }

    private func targetAdd(_ text: String) -> Int32 {
        var entry = Self.normalizedEntry(text)
        guard !entry.isEmpty else {
            err("введите имя команды или путь")
            return ExitCode.usage
        }
        // Найдено у пользователя — запись цели это путь как он лежит, без разворота
        // симлинков: он переживает обновление цели, а разворачивает его охрана.
        let found = foundForSudoCaller(entry)
        if let found { entry = found.path }
        guard !settings.targets.contains(entry) else {
            err("такая цель уже есть в списке")
            return ExitCode.failure
        }
        // Охрана не завершает собственный источник защиты: выбор приложения снимает
        // его из целей, и обратно его туда не пускаем.
        guard entry != settings.vpnAppRule else {
            err("это выбранное VPN-приложение — охрана следит за ним, а не завершает его")
            return ExitCode.failure
        }
        settings.targets += [entry]
        out("Цель добавлена: \(displayName(entry))")
        out("  \(describe(entry))")
        if let found { out("  " + Self.foundInUserPath(user: found.user, path: found.path)) }
        return ExitCode.success
    }

    /// Снять цель по записи или по имени, под которым её показывает `target list`:
    /// записью у bundle id и версионного пути набирать неудобно.
    private func targetRemove(_ text: String) -> Int32 {
        let entry: String
        switch Self.targetToRemove(text, targets: settings.targets, displayName: displayName) {
        case .found(let found):
            entry = found
        case .ambiguous(let entries):
            err("под именем «\(text.trimmingCharacters(in: .whitespaces))» несколько целей — укажите запись: "
                + entries.joined(separator: ", "))
            return ExitCode.failure
        case .missing:
            err("такой цели нет в списке")
            return ExitCode.failure
        }
        settings.targets = settings.targets.filter { $0 != entry }
        out("Цель снята: \(displayName(entry))")
        return ExitCode.success
    }

    enum TargetLookup: Equatable {
        case found(String)
        case ambiguous([String])
        case missing
    }

    /// Запись важнее имени: имя «claude» у записи «claude» и у пути к другой сборке
    /// совпадает, а запись — единственна.
    static func targetToRemove(_ text: String, targets: [String], displayName: (String) -> String) -> TargetLookup {
        let entry = normalizedEntry(text)
        if targets.contains(entry) { return .found(entry) }
        let name = text.trimmingCharacters(in: .whitespaces)
        let named = targets.filter { displayName($0) == name }
        switch named.count {
        case 0: return .missing
        case 1: return .found(named[0])
        default: return .ambiguous(named)
        }
    }

    // MARK: - VPN

    /// Имя интерфейса: 1–15 символов `[A-Za-z0-9_.-]` — столько вмещает `IFNAMSIZ`.
    static func isValidTunnelName(_ name: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        return (1...15).contains(name.unicodeScalars.count)
            && name.unicodeScalars.allSatisfy(allowed.contains)
    }

    static func tunnelMissingWarning(_ name: String) -> String {
        "интерфейса \(name) сейчас нет — пока он не поднимется, охрана считает туннель упавшим и завершает цели"
    }

    private func vpnShow() -> Int32 {
        if let tunnel = settings.vpnTunnel {
            let status = VPNTunnelStatus(chosen: tunnel, snapshot: settledSnapshot())
            out("VPN-туннель: \(tunnel) — \(Self.tunnelStatusText(status))")
        } else if let app = settings.vpnAppRule {
            out("VPN-приложение: \(appDescription(app))")
        } else {
            out("VPN: не задан (охрана работает по гео одной)")
        }
        return ExitCode.success
    }

    /// Снимок с уже известным носителем трафика. Адрес гео-сервиса разрешается
    /// в стороне от опроса — блокировать им охрану нельзя, — поэтому первый снимок
    /// короткоживущей команды носителя ещё не знает. Охране это не мешает, а разовой
    /// команде надо дождаться ответа, иначе она сообщит, что наружу не идёт ничего.
    func settledSnapshot() -> NetworkSnapshot {
        var snapshot = env.snapshotReader.snapshot()
        let deadline = Date().addingTimeInterval(env.snapshotSettleTimeout)
        while snapshot.outgoing == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            snapshot = env.snapshotReader.snapshot()
        }
        return snapshot
    }

    static func tunnelStatusText(_ status: VPNTunnelStatus) -> String {
        switch status {
        case .notChosen: return "не выбран"
        case .down: return "не поднят"
        case .bypassed(let via): return "поднят, но трафик идёт мимо, через \(via)"
        case .carrying: return "несёт трафик"
        }
    }

    /// Что значит значение `vpn set` — одинаково на обеих платформах:
    /// 1. флаг `--tunnel` / `--app` решает сам;
    /// 2. значение с `/` или на `.app` — приложение;
    /// 3. имя существующего сейчас интерфейса (любого, не только поднятого) — туннель;
    /// 4. значение разрешается как цель (файл по `PATH`, bundle id) — приложение;
    /// 5. допустимое имя интерфейса — туннель (с предупреждением, что его сейчас нет);
    /// 6. иначе — `nil`: не найдено ни того, ни другого.
    static func vpnKind(
        of value: String, hint: VPNKindHint, interfaces: [String], resolves: (String) -> Bool
    ) -> VPNKindHint? {
        switch hint {
        case .app, .tunnel: return hint
        case .automatic: break
        }
        if value.contains("/") || value.hasSuffix(".app") { return .app }
        if interfaces.contains(value) { return .tunnel }
        if resolves(value) { return .app }
        if isValidTunnelName(value) { return .tunnel }
        return nil
    }

    static let vpnNotFound = "не найдено ни приложения, ни сетевого интерфейса с таким именем"

    private func vpnSet(_ text: String, _ hint: VPNKindHint) -> Int32 {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else {
            err("введите имя команды или путь")
            return ExitCode.usage
        }
        // Поиск у вызвавшего sudo запускает чужой логин-шелл — не больше одного раза.
        var sudoLookup: (user: String, path: String)??
        let callerFound = { (text: String) -> (user: String, path: String)? in
            if let cached = sudoLookup { return cached }
            let found = self.foundForSudoCaller(Self.normalizedEntry(text))
            sudoLookup = .some(found)
            return found
        }
        let kind = Self.vpnKind(
            of: value, hint: hint, interfaces: env.interfaces.interfaceNames(),
            resolves: { [resolver = env.resolver] in resolver.resolve($0) != nil || callerFound($0) != nil }
        )
        switch kind {
        case .app: return vpnApp(value, found: callerFound(value))
        case .tunnel: return vpnTunnel(value)
        case .automatic, nil:
            err(Self.vpnNotFound)
            return ExitCode.failure
        }
    }

    private func vpnApp(_ text: String, found: (user: String, path: String)?) -> Int32 {
        let entry = found?.path ?? Self.normalizedEntry(text)
        let droppedTunnel = settings.vpnTunnel
        let wasTarget = settings.targets.contains(entry)
        settings.vpnAppRule = entry
        out("VPN-приложение: \(appDescription(entry))")
        if let found { out("  " + Self.foundInUserPath(user: found.user, path: found.path)) }
        if let droppedTunnel { out("VPN-туннель \(droppedTunnel) снят: VPN задаётся одним способом") }
        if wasTarget { out("Цель «\(displayName(entry))» снята: VPN-приложение охрана не завершает") }
        return ExitCode.success
    }

    private func vpnTunnel(_ name: String) -> Int32 {
        guard Self.isValidTunnelName(name) else {
            err("имя интерфейса — от 1 до 15 символов: латиница, цифры, «_», «.» и «-»")
            return ExitCode.usage
        }
        let droppedApp = settings.vpnAppRule
        settings.vpnTunnel = name
        let status = VPNTunnelStatus(chosen: name, snapshot: settledSnapshot())
        out("VPN-туннель: \(name) — \(Self.tunnelStatusText(status))")
        if let droppedApp { out("VPN-приложение \(droppedApp) снято: VPN задаётся одним способом") }
        if !env.interfaces.raisedInterfaces().contains(where: { $0.name == name }) {
            err(Self.tunnelMissingWarning(name))
        }
        return ExitCode.success
    }

    private func vpnList() -> Int32 {
        let raised = env.interfaces.raisedInterfaces()
        let outgoing = settledSnapshot().outgoing
        guard !raised.isEmpty else {
            out("Поднятых интерфейсов нет")
            return ExitCode.success
        }
        for interface in raised {
            let carries = outgoing?.interface == interface.name
            var line = "\(carries ? "*" : " ") \(interface.name)"
            if carries, let outgoing { line += " — трафик наружу идёт здесь (\(outgoing.address))" }
            if interface.name == settings.vpnTunnel { line += " [выбран]" }
            out(line)
        }
        if outgoing == nil { out("Наружу трафик не выпускает никто") }
        return ExitCode.success
    }

    private func vpnClear() -> Int32 {
        settings.vpnAppRule = nil
        settings.vpnTunnel = nil
        out("VPN: не задан (охрана работает по гео одной)")
        return ExitCode.success
    }

    // MARK: - Чёрный и белый списки

    private func geoList(_ kind: GeoListKind) -> Int32 {
        let entries = settings.entries(of: kind)
        if entries.isEmpty { out("Список пуст") }
        for entry in entries { out(entry) }
        return ExitCode.success
    }

    private func geoAdd(_ kind: GeoListKind, _ text: String) -> Int32 {
        switch settings.addEntry(text, to: kind) {
        case .success:
            out("Добавлено: \(Self.storedGeoEntry(text))")
            return ExitCode.success
        case .failure(let error):
            err(error.displayText)
            return error == .duplicate ? ExitCode.failure : ExitCode.usage
        }
    }

    /// Запись ищется в том виде, в каком список её хранит: код страны — заглавными,
    /// диапазон — каноническим текстом.
    static func storedGeoEntry(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.count == 2, trimmed.allSatisfy(\.isLetter) { return trimmed.uppercased() }
        return IPRange(trimmed)?.text ?? trimmed
    }

    private func geoRemove(_ kind: GeoListKind, _ text: String) -> Int32 {
        let entry = Self.storedGeoEntry(text)
        guard settings.entries(of: kind).contains(entry) else {
            err("такой записи нет в списке")
            return ExitCode.failure
        }
        settings.removeEntry(entry, from: kind)
        out("Снято: \(entry)")
        return ExitCode.success
    }

    // MARK: - Токен

    private func tokenSet(_ value: String?) -> Int32 {
        guard let raw = value ?? env.readSecretLine() else {
            err("токен не прочитан из stdin")
            return ExitCode.usage
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            err("токен пуст")
            return ExitCode.usage
        }
        switch settings.setIPInfoToken(token) {
        case .success:
            out("Токен ipinfo задан")
            return ExitCode.success
        case .failure(let error):
            err(error.displayText)
            return ExitCode.failure
        }
    }

    private func tokenClear() -> Int32 {
        switch settings.setIPInfoToken("") {
        case .success:
            out("Токен ipinfo не задан")
            return ExitCode.success
        case .failure(let error):
            err(error.displayText)
            return ExitCode.failure
        }
    }

    // MARK: - Статус и проверка

    /// Обычный пользователь рядом с охраной от root читает её статус: файл `0644`.
    private var statusFile: URL { besideSystemInstall ? env.systemPaths.statusFile : env.paths.statusFile }

    /// Статус живой охраны или `nil`.
    func liveStatus() -> GuardStatus? {
        guard let status = GuardStatus.read(from: statusFile),
              status.isLive(at: env.now(), isAlive: env.guardProcess.isAlive)
        else { return nil }
        return status
    }

    private func status(json: Bool) -> Int32 {
        guard let status = liveStatus() else {
            // Для скрипта (`--json`) — только в stderr: stdout у него JSON или ничего.
            guard !json else {
                err(StatusText.notRunning)
                return ExitCode.notRunning
            }
            // Настройки системной установки лежат у root — пересказать их нечем.
            guard !besideSystemInstall else {
                out(StatusText.notRunningSystem)
                err(Self.systemInstallHint("status"))
                return ExitCode.notRunning
            }
            out(StatusText.notRunning)
            for line in StatusText.settingsSummary(settings, displayName: displayName) { out(line) }
            return ExitCode.notRunning
        }
        if json {
            guard let data = try? status.encoded() else {
                err("не удалось собрать JSON статуса")
                return ExitCode.failure
            }
            out(String(decoding: data, as: UTF8.self))
        } else {
            for line in StatusText.render(status, now: env.now()) { out(line) }
        }
        return ExitCode.success
    }

    private func check() -> Int32 {
        guard let before = liveStatus() else { return checkWithoutGuard() }

        guard env.guardProcess.requestCheck(before.pid) else {
            err("не попросить охрану (pid \(before.pid)): \(String(cString: strerror(errno)))")
            return ExitCode.failure
        }

        // Ожидание считается по настоящим часам: это время, которое человек сидит
        // перед терминалом, а не момент для файла статуса.
        let deadline = Date().addingTimeInterval(env.checkTimeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(env.checkPollInterval))
            guard let current = GuardStatus.read(from: statusFile) else { continue }
            if current.lastProbeAt != before.lastProbeAt, current.lastProbeAt != nil {
                for line in StatusText.render(current, now: env.now()) { out(line) }
                return ExitCode.success
            }
        }
        err("ответа проверки не дождался за \(PauseCeiling.durationText(env.checkTimeout)) — показываю последний статус")
        guard let last = liveStatus() else { return status(json: false) }
        for line in StatusText.render(last, now: env.now()) { out(line) }
        return ExitCode.failure
    }

    /// Охрана не запущена — одна проба в своём процессе. Процессам сигналов
    /// не шлёт: вердикт только печатается.
    private func checkWithoutGuard() -> Int32 {
        let snapshot = settledSnapshot()
        let tunnel = VPNTunnelStatus(chosen: settings.vpnTunnel, snapshot: snapshot)
        let app = vpnAppStatus()
        let probe = env.makeProbe(settings)
        let report = Self.waitFor { await probe.probe() }
        let decision = GuardPolicy.decide(GuardSignals(
            isEnabled: settings.isEnabled, vpn: app, tunnel: tunnel, geo: report.outcome, config: settings.guardConfig
        ))

        out(StatusText.notRunning)
        out("Проверка в этом процессе — цели не трогаются:")
        out("Вердикт:  " + (settings.targets.isEmpty
            ? "цели не выбраны — охрана ничего не завершает"
            : Self.decisionText(decision)))

        let reading: GuardStatus.Reading?
        if case .resolved(let value) = report.outcome {
            reading = GuardStatus.Reading(ip: value.ip, country: value.primaryCountry,
                                          confirmedCountry: value.confirmedCountry,
                                          confirmSource: value.confirmSource?.rawValue)
        } else {
            reading = report.ip.map { GuardStatus.Reading(ip: $0, country: nil, confirmedCountry: nil, confirmSource: nil) }
        }
        let vpn = GuardStatus.vpn(
            appRule: settings.vpnAppRule, appName: settings.vpnAppRule.map(displayName), appStatus: app,
            tunnel: settings.vpnTunnel, tunnelStatus: tunnel
        )
        for line in StatusText.readout(reading: reading, outgoing: snapshot.outgoing.map {
            GuardStatus.Outgoing(interface: $0.interface, address: $0.address)
        }, vpn: vpn) {
            out(line)
        }
        return ExitCode.notRunning
    }

    /// Вердикт разовой проверки: что сделала бы работающая охрана.
    static func decisionText(_ decision: GuardDecision) -> String {
        switch decision {
        case .safe: return "выход безопасен — цели работали бы"
        case .unproven(let reason): return "\(reason.displayText) — работающая охрана поставила бы цели на паузу"
        case .kill(let evidence): return "\(evidence.displayText) — работающая охрана завершила бы цели"
        }
    }

    private func vpnAppStatus() -> VPNAppStatus {
        guard let rule = settings.vpnAppRule else { return .notChosen }
        guard let resolved = env.resolver.resolve(rule) else { return .notRunning }
        let processes = env.locator.allProcesses(includeArguments: resolved.kind == .script)
        return ProcessMatcher.pids(in: processes, rules: [resolved]).isEmpty ? .notRunning : .running
    }

    /// Ждать асинхронный ответ в синхронной команде, не блокируя главный цикл:
    /// пока ждём, главная очередь обслуживается.
    static func waitFor<T>(_ operation: @escaping @Sendable () async -> T) -> T {
        let box = ResultBox<T>()
        Task.detached { box.value = await operation() }
        while box.value == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return box.value!
    }

    private final class ResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T?
        var value: T? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    // MARK: - Журнал

    static let journalLimit = 20

    static func journalStorage(_ paths: CLIPaths) -> EventLogPersisting {
        JournalFile(directory: paths.dataDirectory).map { $0 as EventLogPersisting } ?? InMemoryEventLog()
    }

    static func checksStorage(_ paths: CLIPaths) -> CheckLogPersisting {
        ChecksFile(directory: paths.dataDirectory).map { $0 as CheckLogPersisting } ?? InMemoryCheckLog()
    }

    static func ledgerStorage(_ paths: CLIPaths) -> StoppedLedgerPersisting {
        StoppedFile(directory: paths.dataDirectory).map { $0 as StoppedLedgerPersisting } ?? InMemoryStoppedLedger()
    }

    private func journal(json: Bool) -> Int32 {
        let events = EventLogStore(storage: Self.journalStorage(env.paths)).events
        if json {
            let checks = CheckLogStore(storage: Self.checksStorage(env.paths)).all
            let export = JournalExporter.make(settings: settings, events: events, checks: checks, at: env.now())
            guard let data = try? export.encoded() else {
                err("не удалось собрать выгрузку журнала")
                return ExitCode.failure
            }
            out(String(decoding: data, as: UTF8.self))
            return ExitCode.success
        }
        guard !events.isEmpty else {
            out("Журнал пуст")
            return ExitCode.success
        }
        for event in events.prefix(Self.journalLimit) {
            for line in Self.journalLines(event) { out(line) }
        }
        if events.count > Self.journalLimit {
            out("Показаны последние \(Self.journalLimit) из \(events.count) — выгрузите журнал целиком: weto journal --json")
        }
        return ExitCode.success
    }

    private static let journalDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
        return formatter
    }()

    /// Запись — строка «когда · кто · что и почему», под ней исход эпизода.
    static func journalLines(_ event: KillEvent, timeZone: TimeZone = .current) -> [String] {
        let formatter = journalDate
        formatter.timeZone = timeZone
        let name = event.targetName.isEmpty ? "неизвестная цель" : event.targetName
        var lines = ["\(formatter.string(from: event.date))  \(name) · pid \(event.pid)  \(event.summaryText)"]
        if let resolution = event.resolutionText { lines.append("    Итог: \(resolution)") }
        return lines
    }

    // MARK: - Сервис

    private var serviceManager: ServiceManager {
        // Рядом с охраной от root `service status` показывает её задание:
        // `launchctl print system/…` обычному пользователю доступен.
        ServiceManager(paths: besideSystemInstall ? env.systemPaths : env.paths, control: env.service, uid: env.uid)
    }

    /// Путь к бинарнику после разворота симлинков: сервис и обновление называют файл,
    /// а не ссылку, которую можно перевесить.
    private func resolvedExecutable() -> String? {
        env.executablePath().map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    private func serviceInstall() -> Int32 {
        guard let executable = resolvedExecutable() else {
            err("не удалось определить путь к weto")
            return ExitCode.failure
        }
        let manager = serviceManager
        switch manager.install(executable: executable) {
        case .installed(let warnings):
            for warning in warnings { err(warning) }
            out("сервис установлен: \(env.paths.servicePlist.path)")
            out("охрана запущена: \(CLIPaths.serviceLabel); лог — \(env.paths.logFile.path)")
            return ExitCode.success
        case .reinstalled(let warnings):
            for warning in warnings { err(warning) }
            out("Сервис обновлён и перезапущен: \(CLIPaths.serviceLabel)")
            return ExitCode.success
        case .failed(let message):
            err(message)
            return ExitCode.failure
        }
    }

    private func serviceUninstall() -> Int32 {
        switch serviceManager.uninstall() {
        case .success:
            out("сервис снят: задание \(CLIPaths.serviceLabel) выгружено, файл удалён")
            return ExitCode.success
        case .failure(let error):
            err(error.message)
            return ExitCode.failure
        }
    }

    private func serviceStatus() -> Int32 {
        let manager = serviceManager
        let state = manager.state()
        out("файл:     " + (state.isInstalled ? manager.paths.servicePlist.path : "не установлен"))
        if state.isLoaded {
            var line = "задание:  \(manager.target) загружено"
            if let launchdState = state.launchdState { line += ", состояние \(launchdState)" }
            if let pid = state.runningPID { line += ", pid \(pid)" }
            out(line)
        } else {
            out("задание:  не загружено")
        }
        return ExitCode.success
    }

    // MARK: - Обновление

    private func updateCheck() -> Int32 {
        let source = env.updateSource
        switch Self.waitFor({ await source.check() }) {
        case .success(let verdict):
            out(CLIUpdate.checkLine(verdict))
            return ExitCode.success
        case .failure(let failure):
            err(failure.displayText)
            return ExitCode.failure
        }
    }

    /// Скачать, проверить сумму, заменить бинарник переименованием и перезапустить
    /// сервис: штатный выход старой охраны продолжает стоящие цели, новая подхватывает учёт.
    private func updateInstall() -> Int32 {
        guard let executable = resolvedExecutable() else {
            err("не удалось определить путь к weto")
            return ExitCode.failure
        }
        let source = env.updateSource
        let current: String
        let release: CLIRelease
        switch Self.waitFor({ await source.check() }) {
        case .success(.upToDate(let version)):
            out(CLIUpdate.checkLine(.upToDate(current: version)))
            return ExitCode.success
        case .success(.available(let version, let latest)):
            current = version
            release = latest
        case .success(.noBuildForPlatform(_, let version)):
            // Ставить из такого релиза нечего — отказ из канона установки.
            err(UpdateFailure.missingAsset(version: version, name: CLIUpdate.assetName(version: version)).displayText)
            return ExitCode.failure
        case .failure(let failure):
            err(failure.displayText)
            return ExitCode.failure
        }

        guard env.replacer.canReplace(executable) else {
            err(UpdateFailure.noPermission.displayText)
            return ExitCode.failure
        }
        let unpacker = env.unpacker
        let binary: Data
        switch Self.waitFor({ await source.fetchExecutable(of: release, unpacker: unpacker) }) {
        case .success(let data): binary = data
        case .failure(let failure):
            err(failure.displayText)
            return ExitCode.failure
        }
        if case .failure(let detail) = env.replacer.replace(executable, with: binary) {
            err(UpdateFailure.install(detail.detail).displayText)
            return ExitCode.failure
        }
        out("обновлено: \(current) → \(release.version)")

        var restart = serviceManager.restartIfRunning()
        if restart == .notRunning, env.paths.isSystem, let caller = env.sudoUID, caller != 0 {
            // Системной охраны нет — возможно, бинарник общий, а сервис у того, кто позвал sudo.
            let callerPaths = CLIPaths.user(home: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
            restart = ServiceManager(paths: callerPaths, control: env.service, uid: caller).restartIfRunning()
        }
        switch restart {
        case .notRunning:
            return ExitCode.success
        case .restarted:
            out("сервис перезапущен: \(CLIPaths.serviceLabel)")
            return ExitCode.success
        case .failed(let message):
            err(message)
            return ExitCode.failure
        }
    }
}

/// Чтение токена из stdin. С терминала — без эха: токен не должен остаться
/// ни в истории шелла, ни на экране.
enum SecretInput {
    static func readLine() -> String? {
        guard isatty(STDIN_FILENO) == 1 else { return Swift.readLine(strippingNewline: true) }
        var buffer = [CChar](repeating: 0, count: 512)
        guard readpassphrase("Токен ipinfo: ", &buffer, buffer.count, RPP_ECHO_OFF) != nil else { return nil }
        return String(cString: buffer)
    }
}
