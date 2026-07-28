import Foundation

public enum Constants {

    public static let appVersion = "0.1.0"

    public static let defaultPollIntervalSeconds: TimeInterval = 5

    public static let pollIntervalOptions: [TimeInterval] = [5, 10, 15]

    public static let networkEventDebounceSeconds: TimeInterval = 0.3

    public static let watchdogIntervalSeconds: TimeInterval = 0.25

    public static let geoRequestTimeoutSeconds: TimeInterval = 5

    /// Подтверждение спрашивается уже после ipinfo и удлиняет окно fail-closed,
    /// поэтому ждём его заметно меньше, чем основной источник.
    public static let geoConfirmationTimeoutSeconds: TimeInterval = 2.5

    /// Срок жизни успешного подтверждения страны для неизменного IP. Держит расход
    /// лимита ipwho.is (1000 запросов в сутки) в пределах пары сотен обращений,
    /// но не превращает единичный отказ в вечную блокировку.
    public static let geoConfirmationTTLSeconds: TimeInterval = 600

    public static let ipinfoLiteURL = "https://v4.api.ipinfo.io/lite/me"

    public static func ipwhoisURL(ip: String) -> String { "https://ipwho.is/\(ip)" }

    public static func geojsURL(ip: String) -> String {
        "https://get.geojs.io/v1/ip/country/\(ip).json"
    }

    public static let eventLogCapacity = 10

    public static let userDefaultsSuite = "com.weto.shared"

    public static let keychainService = "com.weto.ipinfo"

    public static let githubOwner = "squaretus"

    public static let githubRepo = "weto"

    public static var githubRepoURL: String {
        "https://github.com/\(githubOwner)/\(githubRepo)"
    }

    public static let updateCheckInterval: TimeInterval = 21_600

}
