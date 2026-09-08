import Foundation
import WetoCore

/// Ответ границы целиком: тело, код, время и фазы запроса.
public struct HTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public let duration: TimeInterval
    public let phases: NetworkPhases?

    public init(data: Data, statusCode: Int, duration: TimeInterval, phases: NetworkPhases? = nil) {
        self.data = data
        self.statusCode = statusCode
        self.duration = duration
        self.phases = phases
    }
}

public protocol HTTPFetching: Sendable {
    func fetch(from url: URL, headers: [String: String]) async throws -> HTTPResponse
}

/// Отказ по коду ответа несёт с собой сам ответ: тело у 429 и 403 и объясняет отказ.
public struct HTTPFetchError: LocalizedError {
    public let statusCode: Int
    public let response: HTTPResponse

    public init(statusCode: Int, response: HTTPResponse) {
        self.statusCode = statusCode
        self.response = response
    }

    public var errorDescription: String? { "HTTP \(statusCode)" }
}

/// Транспортный отказ несёт фазы: таймаут на DNS и таймаут на ожидании ответа —
/// разные диагнозы (мёртвый туннель против медленного сервиса), а `URLError`
/// у них один и тот же.
public struct HTTPTransportError: LocalizedError {
    public let underlying: Error
    public let phases: NetworkPhases?

    public init(underlying: Error, phases: NetworkPhases?) {
        self.underlying = underlying
        self.phases = phases
    }

    public var errorDescription: String? { underlying.localizedDescription }
}

public struct URLSessionHTTPFetcher: HTTPFetching {

    private let session: URLSession
    private let metrics: MetricsCollector

    public init(timeout: TimeInterval = Constants.geoRequestTimeoutSeconds) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        let collector = MetricsCollector()
        self.metrics = collector
        self.session = URLSession(configuration: configuration, delegate: collector, delegateQueue: nil)
    }

    public func fetch(from url: URL, headers: [String: String]) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let started = ContinuousClock.now
        let data: Data
        let response: URLResponse
        let task = session.dataTask(with: request)
        do {
            (data, response) = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    metrics.register(task, continuation: continuation)
                    task.resume()
                }
            } onCancel: { task.cancel() }
        } catch {
            throw HTTPTransportError(underlying: error, phases: metrics.take(task))
        }
        let elapsed = ContinuousClock.now - started
        let duration = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let answer = HTTPResponse(data: data, statusCode: status, duration: duration, phases: metrics.take(task))
        if !(200..<300).contains(status) {
            throw HTTPFetchError(statusCode: status, response: answer)
        }
        return answer
    }
}

/// Делегат сессии: копит метрики задач и отдаёт данные через continuation.
/// `data(for:)` метрик не отдаёт, поэтому задача ведётся руками.
private final class MetricsCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [Int: Data] = [:]
    private var phases: [Int: NetworkPhases] = [:]
    private var continuations: [Int: CheckedContinuation<(Data, URLResponse), Error>] = [:]

    func register(_ task: URLSessionTask, continuation: CheckedContinuation<(Data, URLResponse), Error>) {
        lock.lock(); continuations[task.taskIdentifier] = continuation; buffers[task.taskIdentifier] = Data(); lock.unlock()
    }

    /// Фазы задачи — один раз: после выдачи запись стирается.
    func take(_ task: URLSessionTask) -> NetworkPhases? {
        lock.lock(); defer { lock.unlock() }
        return phases.removeValue(forKey: task.taskIdentifier)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); buffers[dataTask.taskIdentifier]?.append(data); lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        // Последняя транзакция — та, что дошла до сервера (редиректы здесь не ждём).
        guard let transaction = metrics.transactionMetrics.last else { return }
        let phase = Self.phases(of: transaction)
        lock.lock(); phases[task.taskIdentifier] = phase; lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: task.taskIdentifier)
        let body = buffers.removeValue(forKey: task.taskIdentifier) ?? Data()
        lock.unlock()

        if let error {
            continuation?.resume(throwing: error)
        } else if let response = task.response {
            continuation?.resume(returning: (body, response))
        } else {
            continuation?.resume(throwing: URLError(.badServerResponse))
        }
    }

    /// Длительность каждой фазы. Незавершённая фаза — `nil`; фаза, которой не было
    /// (TLS у http, DNS у адреса-литерала, соединение у переиспользованного
    /// keep-alive — `isReusedConnection`, а не только адрес-литерал) — `0`: иначе
    /// `stalledPhase` укажет на неё у полностью успешного запроса, а на переиспользованном
    /// соединении принял бы застрявший `firstByte` за застрявший `connect`.
    static func phases(of transaction: URLSessionTaskTransactionMetrics) -> NetworkPhases {
        func span(_ start: Date?, _ end: Date?) -> Int? {
            guard let start, let end else { return nil }
            return Int((end.timeIntervalSince(start) * 1000).rounded())
        }
        let dns = transaction.domainLookupStartDate == nil
            ? 0 : span(transaction.domainLookupStartDate, transaction.domainLookupEndDate)
        let connect = transaction.isReusedConnection
            ? 0 : span(transaction.connectStartDate, transaction.connectEndDate)
        let tls = transaction.secureConnectionStartDate == nil
            ? 0 : span(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate)
        let firstByte = span(transaction.requestStartDate, transaction.responseStartDate)
        return NetworkPhases(
            dnsMilliseconds: dns,
            connectMilliseconds: connect,
            tlsMilliseconds: tls,
            firstByteMilliseconds: firstByte
        )
    }
}
