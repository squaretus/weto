import XCTest
import Darwin
@testable import WetoSystem
import WetoCore

/// Читает один HTTP-запрос из сокета до `\r\n\r\n` — ровно чтобы сервер знал,
/// что клиент закончил отправку, и мог не отвечать намеренно. Свободная функция,
/// а не метод: используется из `Thread`-замыкания, и `self` там ловить незачем.
private func readRequestHeaders(_ fd: Int32) {
    var collected = [UInt8]()
    var byte: UInt8 = 0
    while collected.count < 4 || collected.suffix(4) != [13, 10, 13, 10] {
        let n = read(fd, &byte, 1)
        guard n > 0 else { return }
        collected.append(byte)
    }
}

final class HTTPFetcherPhasesTests: XCTestCase {

    /// Сокет, который слушает, но никогда не отвечает: соединение проходит через backlog,
    /// а первого байта не будет. Так выглядит молчащий сервис при живом туннеле.
    private func silentListener() throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, 8), 0)

        var bound_address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound_address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(fd, $0, &length)
            }
        }
        return (fd, UInt16(bigEndian: bound_address.sin_port))
    }

    func test_timeout_while_waiting_for_the_first_byte_reports_connect_done() async throws {
        let (fd, port) = try silentListener()
        defer { close(fd) }
        let fetcher = URLSessionHTTPFetcher(timeout: 0.5)

        do {
            _ = try await fetcher.fetch(from: URL(string: "http://127.0.0.1:\(port)/")!, headers: [:])
            XCTFail("сервис не отвечает — запрос обязан упасть по таймауту")
        } catch let transport as HTTPTransportError {
            let phases = try XCTUnwrap(transport.phases, "фазы обязаны быть даже у упавшего запроса")
            XCTAssertNotNil(phases.connectMilliseconds, "соединение состоялось")
            XCTAssertNil(phases.firstByteMilliseconds, "первого байта не было")
            XCTAssertEqual(phases.stalledPhase, .firstByte)
            XCTAssertEqual((transport.underlying as? URLError)?.code, .timedOut)
        }
    }

    /// Каждая проба — своё соединение. Туннель с подменой адресов (Happ на `utun6`,
    /// `198.18.0.1`) при перезапуске или смене узла молча бросает живые TCP-соединения —
    /// без RST, — а отпечаток выхода при этом не меняется. Сессия, жившая всё время
    /// приложения, раз за разом отдавала пробе мёртвое соединение из своего пула: фазы
    /// DNS, соединения и TLS — нули (`isReusedConnection`), ожидание ответа — до таймаута,
    /// и так минутами подряд, пока система сама не выбросит соединение. Цели вставали
    /// на паузу при исправном VPN.
    ///
    /// Сервер отвечает на первый запрос и держит то соединение открытым, но молчащим;
    /// второй запрос обязан прийти новым соединением и получить ответ.
    func test_a_silent_pooled_connection_is_not_reused_by_the_next_request() async throws {
        let (fd, port) = try silentListener()
        defer { close(fd) }
        let responder = Thread {
            let answer = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
            // Первое соединение: ответ и молчание. Не закрывается — так выглядит
            // соединение, брошенное туннелем: снаружи живое, внутри мёртвое.
            let first = accept(fd, nil, nil)
            guard first >= 0 else { return }
            readRequestHeaders(first)
            _ = answer.withCString { write(first, $0, strlen($0)) }
            // Второе соединение: ответ. Если клиент переиспользует первое,
            // сюда он не придёт никогда.
            let second = accept(fd, nil, nil)
            guard second >= 0 else { return }
            readRequestHeaders(second)
            _ = answer.withCString { write(second, $0, strlen($0)) }
            close(second)
        }
        responder.start()

        let fetcher = URLSessionHTTPFetcher(timeout: 1)
        let url = URL(string: "http://127.0.0.1:\(port)/")!

        let first = try await fetcher.fetch(from: url, headers: [:])
        XCTAssertEqual(first.statusCode, 200)

        // Отвечает сервер только на втором соединении, поэтому сам ответ и доказывает,
        // что запрос не пошёл в молчащее первое. Фазы тут не судья: соединение
        // на loopback открывается быстрее миллисекунды и округляется в тот же ноль.
        let second = try await fetcher.fetch(from: url, headers: [:])
        XCTAssertEqual(second.statusCode, 200, "ответ пришёл новым соединением")
    }

    func test_successful_request_carries_all_phases() async throws {
        // Сервер, отвечающий одной строкой: живой `Process` с `nc` тянет зависимость
        // от окружения, поэтому ответ пишется руками в принятое соединение.
        let (fd, port) = try silentListener()
        defer { close(fd) }
        let responder = Thread {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            // Запрос дочитывается до ответа: закрытый сокет с непрочитанными байтами
            // ядро сбрасывает RST, URLSession повторяет GET новым соединением,
            // а принять его уже некому — на раннере GitHub это кончилось таймаутом.
            readRequestHeaders(client)
            let body = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
            _ = body.withCString { write(client, $0, strlen($0)) }
            close(client)
        }
        responder.start()

        let fetcher = URLSessionHTTPFetcher(timeout: 5)
        let answer = try await fetcher.fetch(from: URL(string: "http://127.0.0.1:\(port)/")!, headers: [:])

        XCTAssertEqual(answer.statusCode, 200)
        let phases = try XCTUnwrap(answer.phases)
        XCTAssertNotNil(phases.connectMilliseconds)
        XCTAssertNotNil(phases.firstByteMilliseconds)
        XCTAssertEqual(phases.tlsMilliseconds, 0, "у http нет TLS — фаза не «не завершилась», а не нужна")
        XCTAssertNil(phases.stalledPhase)
    }
}
