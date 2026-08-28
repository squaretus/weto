import Foundation

/// Одна попытка проверки подключения.
///
/// Журнал завершений отвечает на вопрос «почему умерли цели». На вопрос «я нажал
/// проверить, и ничего не произошло» он не отвечает вовсе: нажатие, не породившее
/// завершения, не оставляет следа. Отсюда второй журнал — про сами проверки,
/// включая те, где запрос так и не ушёл.
///
/// В интерфейс не попадает никогда: это материал выгрузки.
public struct CheckEvent: Codable, Equatable, Identifiable, Sendable {

    /// Что вызвало проверку.
    public enum Trigger: String, Codable, Equatable, Sendable {
        /// Кнопка «проверить» в попапе.
        case manual
        /// Сменился путь наружу — интерфейс или локальный адрес.
        case networkChange
        /// Расписание гео.
        case schedule
        /// Правка настроек обесценила вердикт.
        case settingsChange

        public var displayText: String {
            switch self {
            case .manual: return "кнопка «проверить»"
            case .networkChange: return "сменился путь наружу"
            case .schedule: return "расписание"
            case .settingsChange: return "правка настроек"
            }
        }
    }

    /// Чем попытка кончилась.
    public enum Outcome: String, Codable, Equatable, Sendable {
        /// Запрос ушёл и вернулся с адресом и страной.
        case answered
        /// Запрос ушёл, но годного ответа не дал.
        case failed
        /// Запрос не ушёл: другая проба ещё в полёте.
        ///
        /// Ровно это и означает «нажал пять раз, а ничего не поехало».
        case skippedProbeInFlight
        /// Ответ пришёл, но описывает уже не нас: путь сменился, пока проба летела.
        case discardedPathChanged
        /// Ответ пришёл, но настройки успели измениться.
        case discardedSettingsChanged

        public var displayText: String {
            switch self {
            case .answered: return "ответ получен"
            case .failed: return "ответа нет"
            case .skippedProbeInFlight: return "запрос не отправлен: проба уже в полёте"
            case .discardedPathChanged: return "ответ отброшен: путь сменился"
            case .discardedSettingsChanged: return "ответ отброшен: настройки изменились"
            }
        }

        /// Запрос действительно ушёл и вернулся ни с чем — единственное, что стоит
        /// записывать из расписания. Всё остальное там рутина: удача не говорит
        /// ничего, а пропуски раз в пять секунд съели бы ёмкость за четыре минуты.
        public var isFailedRequest: Bool { self == .failed }
    }

    public let id: UUID
    public let date: Date
    public let trigger: Trigger
    public let outcome: Outcome

    /// Отпечаток выхода на момент проверки: интерфейс и локальный адрес.
    public let fingerprint: String?

    public let durationMilliseconds: Int?

    public let ip: String?
    public let country: String?
    public let confirmedCountry: String?
    public let confirmSource: String?

    /// Что ответил каждый сервис до разбора.
    public let services: [GeoServiceTrace]

    /// Подробность отказа — то, что не выражается кодом исхода.
    public let detail: String?

    public init(
        id: UUID = UUID(),
        date: Date,
        trigger: Trigger,
        outcome: Outcome,
        fingerprint: String? = nil,
        durationMilliseconds: Int? = nil,
        ip: String? = nil,
        country: String? = nil,
        confirmedCountry: String? = nil,
        confirmSource: String? = nil,
        services: [GeoServiceTrace] = [],
        detail: String? = nil
    ) {
        self.id = id
        self.date = date
        self.trigger = trigger
        self.outcome = outcome
        self.fingerprint = fingerprint
        self.durationMilliseconds = durationMilliseconds
        self.ip = ip
        self.country = country
        self.confirmedCountry = confirmedCountry
        self.confirmSource = confirmSource
        self.services = services
        self.detail = detail
    }

    /// Пишется ли такая проверка в журнал.
    ///
    /// Всё, что попросил пользователь или потребовала смена обстановки, пишется
    /// всегда. Из расписания — только состоявшийся запрос без ответа: рутина
    /// раз в пять секунд съела бы ёмкость за четыре минуты и не сказала бы ничего.
    public var isWorthRecording: Bool {
        switch trigger {
        case .manual, .networkChange, .settingsChange:
            return true
        case .schedule:
            return outcome.isFailedRequest
        }
    }
}

extension CheckEvent {

    public static func decodeLog(_ data: Data) throws -> [CheckEvent] {
        try JSONDecoder().decode([CheckEvent].self, from: data)
    }

    public static func encodeLog(_ events: [CheckEvent]) throws -> Data {
        try JSONEncoder().encode(events)
    }
}
