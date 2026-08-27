import Foundation

/// Журнал, выгруженный для разбора.
///
/// Не голый массив записей, а конверт: по одним событиям не понять, что было
/// настроено в тот момент, а именно этот вопрос и задают, разбирая «почему цели
/// завершились». Токен ipinfo сюда не попадает — ни в настройках, ни в трассах,
/// где он и не появляется, потому что уходит заголовком.
public struct JournalExport: Codable, Equatable, Sendable {

    /// Версия формата. Меняется, когда старый разбор перестаёт понимать новый файл.
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let exportedAt: Date
    public let app: App
    public let settings: Settings
    public let events: [KillEvent]

    public struct App: Codable, Equatable, Sendable {
        public let version: String
        public let platform: String
        public let osVersion: String

        public init(version: String, platform: String, osVersion: String) {
            self.version = version
            self.platform = platform
            self.osVersion = osVersion
        }
    }

    /// Снимок настроек без единого секрета.
    public struct Settings: Codable, Equatable, Sendable {
        public let isEnabled: Bool
        public let vpnAppRule: String?
        public let targets: [String]
        public let blockedCountries: [String]
        public let blockedIPRanges: [String]
        public let allowedCountries: [String]
        public let allowedIPRanges: [String]

        /// Токена нет и быть не может: он не поле настроек, а отдельное хранилище.
        /// Признак «задан ли» при этом полезен — без него отказ ipinfo не объяснить.
        public let hasIPInfoToken: Bool

        public init(
            isEnabled: Bool,
            vpnAppRule: String?,
            targets: [String],
            blockedCountries: [String],
            blockedIPRanges: [String],
            allowedCountries: [String],
            allowedIPRanges: [String],
            hasIPInfoToken: Bool
        ) {
            self.isEnabled = isEnabled
            self.vpnAppRule = vpnAppRule
            self.targets = targets
            self.blockedCountries = blockedCountries.sorted()
            self.blockedIPRanges = blockedIPRanges
            self.allowedCountries = allowedCountries.sorted()
            self.allowedIPRanges = allowedIPRanges
            self.hasIPInfoToken = hasIPInfoToken
        }
    }

    public init(
        exportedAt: Date,
        app: App,
        settings: Settings,
        events: [KillEvent],
        schemaVersion: Int = JournalExport.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.app = app
        self.settings = settings
        self.events = events
    }

    /// Файл читают и человек, и агент, поэтому он отсортирован по ключам,
    /// с отступами и датами по ISO 8601: разница двух выгрузок должна быть
    /// разницей событий, а не порядка ключей.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> JournalExport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(JournalExport.self, from: data)
    }

    /// Имя файла по умолчанию: с точностью до минуты и без пробелов, чтобы его
    /// можно было приложить куда угодно, не переименовывая.
    public static func fileName(at moment: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "weto-journal-\(formatter.string(from: moment)).json"
    }
}
