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

    /// Второй запрос через тот же `URLSessionHTTPFetcher` на тот же адрес обычно переиспользует
    /// keep-alive-соединение: `connectStartDate`/`connectEndDate` у такой транзакции — `nil`
    /// не потому что фаза не завершилась, а потому что её не было вовсе. Сервер отвечает
    /// на первый запрос и держит то же соединение открытым, на второй — молчит, чтобы
    /// запрос упёрся в ожидание первого байта на переиспользованном соединении.
    func test_reused_connection_reports_connect_as_not_needed_not_stalled() async throws {
        let (fd, port) = try silentListener()
        defer { close(fd) }
        let responder = Thread {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            readRequestHeaders(client)
            let body = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
            _ = body.withCString { write(client, $0, strlen($0)) }
            // Соединение НЕ закрывается: второй запрос обязан прийти по нему же.
            readRequestHeaders(client)
            // На второй запрос сервер намеренно не отвечает.
        }
        responder.start()

        let fetcher = URLSessionHTTPFetcher(timeout: 0.5)
        let url = URL(string: "http://127.0.0.1:\(port)/")!

        let first = try await fetcher.fetch(from: url, headers: [:])
        XCTAssertEqual(first.statusCode, 200)

        do {
            _ = try await fetcher.fetch(from: url, headers: [:])
            XCTFail("второй запрос не получает ответа — обязан упасть по таймауту")
        } catch let transport as HTTPTransportError {
            let phases = try XCTUnwrap(transport.phases, "фазы обязаны быть даже у упавшего запроса")
            XCTAssertEqual(
                phases.connectMilliseconds, 0,
                "соединение переиспользовано — это «фазы не было», а не «не завершилась»"
            )
            XCTAssertNil(phases.firstByteMilliseconds, "первого байта не было")
            XCTAssertEqual(
                phases.stalledPhase, .firstByte,
                "застряли на ожидании ответа, а не на соединении — оно уже было"
            )
        }
    }

    func test_successful_request_carries_all_phases() async throws {
        // Сервер, отвечающий одной строкой: живой `Process` с `nc` тянет зависимость
        // от окружения, поэтому ответ пишется руками в принятое соединение.
        let (fd, port) = try silentListener()
        defer { close(fd) }
        let responder = Thread {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
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
