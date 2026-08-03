import XCTest
@testable import WetoCore

final class GeoFailureTests: XCTestCase {

    func test_rejected_token_is_named_together_with_its_status() {
        XCTAssertEqual(GeoFailure(httpStatus: 401), .unauthorized(401))
        XCTAssertEqual(GeoFailure(httpStatus: 401).displayText, "токен отвергнут (401)")
    }

    func test_exhausted_quota_is_told_apart_from_a_rejected_token() {
        XCTAssertEqual(GeoFailure(httpStatus: 429), .rateLimited(429))
        XCTAssertEqual(GeoFailure(httpStatus: 429).displayText, "лимит запросов (429)")
    }

    func test_service_side_error_does_not_blame_the_token() {
        XCTAssertEqual(GeoFailure(httpStatus: 503), .serviceError(503))
        XCTAssertEqual(GeoFailure(httpStatus: 503).displayText, "сервис ответил ошибкой (503)")
    }

    func test_absent_connection_is_reported_as_no_network() {
        let failure = GeoFailure(urlErrorCode: -1009, description: "The Internet connection appears to be offline.")

        XCTAssertEqual(failure, .noNetwork)
        XCTAssertEqual(failure.displayText, "нет сети")
    }

    func test_silent_service_is_reported_as_timeout() {
        let failure = GeoFailure(urlErrorCode: -1001, description: "The request timed out.")

        XCTAssertEqual(failure, .timedOut)
        XCTAssertEqual(failure.displayText, "таймаут запроса")
    }

    // Обрыв соединения и провал DNS — не «нет сети»: путь наружу может быть жив,
    // а строку «сеть» рядом заполняет системный монитор, и врать ей нельзя.
    func test_lost_connection_and_failed_lookup_read_as_unreachable_service() {
        XCTAssertEqual(GeoFailure(urlErrorCode: -1005, description: ""), .unreachable)
        XCTAssertEqual(GeoFailure(urlErrorCode: -1003, description: ""), .unreachable)
        XCTAssertEqual(GeoFailure(urlErrorCode: -1006, description: "").displayText, "сервис недоступен")
    }

    // Страховка на случай, когда классификация промахнулась: показать сырой текст
    // системы честнее, чем выдать незнакомый код за отсутствие сети.
    func test_unmapped_code_keeps_the_original_wording() {
        let failure = GeoFailure(urlErrorCode: -1202, description: "Сертификат сервера недействителен.")

        XCTAssertEqual(failure, .other("Сертификат сервера недействителен."))
        XCTAssertEqual(failure.displayText, "Сертификат сервера недействителен.")
    }
}
