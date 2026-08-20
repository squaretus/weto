import Foundation

public enum Constants {

    public static let appBundleIdentifier = "com.weto.app"

    /// Версия берётся из Info.plist собранного бандла, а не хранится в исходнике:
    /// релизный скрипт больше не правит отслеживаемые файлы через sed.
    /// Идентификатор бандла проверяется намеренно: при запуске через `swift run`
    /// или из тестов `Bundle.main` — чужой бандл, и его версия к нам не относится.
    public static let appVersion: String = {
        guard Bundle.main.bundleIdentifier == appBundleIdentifier,
              let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        else { return "dev" }
        return version
    }()

    public static let defaultPollIntervalSeconds: TimeInterval = 5

    public static let pollIntervalOptions: [TimeInterval] = [5, 10, 15]

    /// Как часто уходит запрос к гео-сервисам. Отдельно от опроса системы: опрос
    /// бесплатный и частый, обращение к чужим сервисам платное и редкое, и учащение
    /// первого не должно жечь лимиты второго.
    public static let geoProbeIntervalSeconds: TimeInterval = 5

    public static let networkEventDebounceSeconds: TimeInterval = 0.3

    public static let watchdogIntervalSeconds: TimeInterval = 0.25

    /// Как часто цель разрешается в правило заново. Путь бинарника, развёрнутый
    /// через симлинки, у многих инструментов содержит номер версии
    /// (`.local/share/claude/versions/2.1.228`), и обновление меняет его целиком.
    /// Разрешённое однажды правило устаревало молча: цель пропадала из запущенных
    /// и переставала завершаться при падении VPN, пока её не добавят заново.
    /// Интервал заметно короче штатного тика, поэтому к решению охраны
    /// правила приходят уже свежими.
    public static let targetRuleRefreshSeconds: TimeInterval = 2

    public static let geoRequestTimeoutSeconds: TimeInterval = 5

    /// Подтверждение спрашивается уже после ipinfo и удлиняет окно fail-closed,
    /// поэтому ждём его заметно меньше, чем основной источник.
    public static let geoConfirmationTimeoutSeconds: TimeInterval = 2.5

    /// Мягкий потолок ответа подтверждающего сервиса: по нему делается попытка переспросить
    /// про тот же адрес. Неудача ничего не меняет — годный ответ у нас уже есть, и отказ
    /// чужого сервиса не повод завершать цели.
    public static let confirmationSoftTTLSeconds: TimeInterval = 60

    /// Жёсткий потолок: дольше этого доверять одному ответу нельзя. У переприсвоенных
    /// диапазонов страна регистрации меняется, и подтверждение обязано обновиться
    /// или признаться недоступным.
    public static let confirmationHardTTLSeconds: TimeInterval = 900

    public static let ipinfoLiteURL = "https://v4.api.ipinfo.io/lite/me"

    /// Канонический адрес без редиректа: freeipapi.com отвечает 302 на free.freeipapi.com.
    /// Лимит — 60 запросов в минуту, и считается он на клиентский адрес, то есть
    /// на выход VPN: делим его с другими клиентами того же узла. Поэтому подтверждение
    /// спрашивается не на каждой пробе, а по смене адреса и по мягкому потолку —
    /// один запрос в минуту вместо двенадцати.
    public static func freeipapiURL(ip: String) -> String {
        "https://free.freeipapi.com/api/json/\(ip)"
    }

    public static func geojsURL(ip: String) -> String {
        "https://get.geojs.io/v1/ip/country/\(ip).json"
    }

    /// Тот же сервис, но про самого звонящего: адрес на входе не нужен.
    /// Единственный источник, который отвечает без токена, — поэтому справочная
    /// строка на свежей установке берётся отсюда.
    public static let geojsSelfURL = "https://get.geojs.io/v1/ip/country.json"

    public static let eventLogCapacity = 10

    public static let userDefaultsSuite = "com.weto.shared"

    public static let keychainService = "com.weto.ipinfo"

    /// Ссылка в футере настроек. Владелец и репозиторий известны конфигурации
    /// обновления — второго места с этими строками быть не должно.
    public static var githubRepoURL: String { WetoUpdate.configuration.repositoryURL }

}
