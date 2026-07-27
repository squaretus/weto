import Foundation

/// Именованные константы проекта. Caseless enum предотвращает создание экземпляров.
public enum Constants {

    // MARK: - Версия

    /// Версия приложения. Подставляется `scripts/build.sh` при сборке релиза.
    public static let appVersion = "0.1.0"

    // MARK: - Опрос

    /// Интервал фонового такта по умолчанию, секунды.
    public static let defaultPollIntervalSeconds: TimeInterval = 5

    /// Доступные интервалы опроса в настройках, секунды.
    public static let pollIntervalOptions: [TimeInterval] = [5, 10, 15, 30]

    /// Окно коалесценции сетевых событий, секунды.
    /// При переключении Wi-Fi система выдаёт пачку из 5–10 уведомлений за секунду.
    public static let networkEventDebounceSeconds: TimeInterval = 0.3

    /// Период добивающего таймера, пока состояние небезопасно, секунды.
    ///
    /// Частый поллинг — единственный способ поймать терминальные процессы:
    /// `NSWorkspace.didLaunchApplicationNotification` приходит только про
    /// GUI-приложения. Полный обход всех процессов вместе с командными
    /// строками стоит около 5 мс, так что четверть секунды практически бесплатна.
    public static let watchdogIntervalSeconds: TimeInterval = 0.25

    /// Таймаут любого гео-запроса, секунды.
    public static let geoRequestTimeoutSeconds: TimeInterval = 5

    // MARK: - Гео-сервисы

    /// Единственный источник внешнего IP. Хост `v4.` принудительно использует IPv4.
    public static let ipinfoLiteURL = "https://v4.api.ipinfo.io/lite/me"

    /// Основной подтверждающий сервис. Лимит 1000 запросов в сутки, поэтому
    /// вызывается только при смене IP.
    public static func ipwhoisURL(ip: String) -> String { "https://ipwho.is/\(ip)" }

    /// Резервный подтверждающий сервис. Лимит не задокументирован — отсюда роль резерва.
    public static func geojsURL(ip: String) -> String {
        "https://get.geojs.io/v1/ip/country/\(ip).json"
    }

    // MARK: - Дефолты политики

    /// Заблокированные страны по умолчанию.
    public static let defaultBlockedCountries: Set<String> = ["RU"]

    // MARK: - Журнал

    /// Размер кольцевого буфера журнала срабатываний.
    /// Записи старше десятой отбрасываются автоматически.
    public static let eventLogCapacity = 10

    /// Сколько последних событий показывать в попапе менюбара.
    public static let eventLogPreviewCount = 5

    // MARK: - Хранилище

    /// Suite `UserDefaults`, общий для приложения и демона.
    public static let userDefaultsSuite = "com.weto.shared"

    /// Сервис Keychain для токена ipinfo.
    public static let keychainService = "com.weto.ipinfo"

    // MARK: - Автообновление

    /// GitHub owner. Уточняется владельцем перед первым релизом.
    public static let githubOwner = "squaretus"

    /// GitHub repo. Уточняется владельцем перед первым релизом.
    public static let githubRepo = "weto"

    /// Интервал проверки обновлений, секунды (6 часов).
    public static let updateCheckInterval: TimeInterval = 21_600

    /// Задержка первой проверки после старта демона, секунды.
    public static let updateCheckInitialDelay: TimeInterval = 10

    /// Каталог для скачанного PKG, root-only 0700.
    public static let updatesDirectory = "/var/db/weto/updates"
}
