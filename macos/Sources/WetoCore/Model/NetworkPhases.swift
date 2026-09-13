import Foundation

/// Фаза сетевого запроса. Нужна ровно для одного вопроса: мёртв туннель или медленен сервис.
/// Таймаут на DNS и на соединении — туннель не пропускает пакеты; таймаут на ожидании
/// ответа — соединение живо, молчит сервис.
public enum NetworkPhase: String, Codable, Equatable, Sendable {
    case dns
    case connect
    case tls
    case firstByte

    public var displayText: String {
        switch self {
        case .dns: return "DNS"
        case .connect: return "соединение"
        case .tls: return "TLS"
        case .firstByte: return "ожидание ответа"
        }
    }
}

/// Длительности фаз одного запроса в миллисекундах. `nil` — фаза не завершилась
/// (или не было нужды: TLS у http-запроса). Значения снимаются на границе
/// из метрик задачи URL-сессии, здесь — только их разбор.
public struct NetworkPhases: Codable, Equatable, Sendable {
    public let dnsMilliseconds: Int?
    public let connectMilliseconds: Int?
    public let tlsMilliseconds: Int?
    public let firstByteMilliseconds: Int?

    public init(
        dnsMilliseconds: Int?,
        connectMilliseconds: Int?,
        tlsMilliseconds: Int?,
        firstByteMilliseconds: Int?
    ) {
        self.dnsMilliseconds = dnsMilliseconds
        self.connectMilliseconds = connectMilliseconds
        self.tlsMilliseconds = tlsMilliseconds
        self.firstByteMilliseconds = firstByteMilliseconds
    }

    /// Первая незавершённая фаза — та, на которой запрос и застрял. `nil` — ответ пришёл.
    public var stalledPhase: NetworkPhase? {
        if dnsMilliseconds == nil { return .dns }
        if connectMilliseconds == nil { return .connect }
        if tlsMilliseconds == nil { return .tls }
        if firstByteMilliseconds == nil { return .firstByte }
        return nil
    }
}
