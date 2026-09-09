import XCTest
@testable import WetoCore

final class GeoResponsesTests: XCTestCase {

    private let ipinfoJSON = Data("""
    {"ip":"203.0.113.28","asn":"AS49791","as_name":"Newserverlife LLC",
     "as_domain":"3hcloud.com","country_code":"KZ","country":"Kazakhstan",
     "continent_code":"AS","continent":"Asia"}
    """.utf8)

    // Форма ответа снята с живого free.freeipapi.com: ключи в camelCase.
    private let freeipapiJSON = Data("""
    {"ipVersion":4,"ipAddress":"203.0.113.28","latitude":43.238,"longitude":76.8829,
     "countryName":"Kazakhstan","countryCode":"KZ","capital":"Astana",
     "timeZones":["Asia/Almaty"],"zipCode":"050000","cityName":"Almaty"}
    """.utf8)

    private let geojsJSON = Data("""
    {"country":"KZ","country_3":"KAZ","ip":"203.0.113.28","name":"Kazakhstan"}
    """.utf8)

    func test_ipinfo_response_is_decoded() throws {
        let response = try GeoResponses.decodeIPInfo(ipinfoJSON)
        XCTAssertEqual(response.ip, "203.0.113.28")
        XCTAssertEqual(response.countryCode, "KZ")
    }

    func test_freeipapi_response_yields_country_code() throws {
        XCTAssertEqual(try GeoResponses.decodeFreeIPAPI(freeipapiJSON), "KZ")
    }

    func test_freeipapi_response_without_country_yields_nil() throws {

        let empty = Data(#"{"ipVersion":4,"ipAddress":"1.1.1.1","countryCode":""}"#.utf8)
        XCTAssertNil(try GeoResponses.decodeFreeIPAPI(empty))

        let missing = Data(#"{"ipVersion":4,"ipAddress":"1.1.1.1"}"#.utf8)
        XCTAssertNil(try GeoResponses.decodeFreeIPAPI(missing))
    }

    func test_geojs_response_yields_country_code() throws {
        XCTAssertEqual(try GeoResponses.decodeGeoJS(geojsJSON), "KZ")
    }

    func test_reading_is_assembled_from_ipinfo_and_confirmation() throws {
        let response = try GeoResponses.decodeIPInfo(ipinfoJSON)
        let reading = GeoResponses.makeReading(
            ipinfo: response,
            confirmedCountry: "KZ",
            source: .freeipapi
        )
        XCTAssertEqual(reading.ip, "203.0.113.28")
        XCTAssertEqual(reading.primaryCountry, "KZ")
        XCTAssertEqual(reading.confirmedCountry, "KZ")
        XCTAssertEqual(reading.confirmSource, .freeipapi)
    }

    func test_reading_without_confirmation_keeps_nil_source() throws {
        let response = try GeoResponses.decodeIPInfo(ipinfoJSON)
        let reading = GeoResponses.makeReading(
            ipinfo: response,
            confirmedCountry: nil,
            source: nil
        )
        XCTAssertNil(reading.confirmedCountry)
        XCTAssertNil(reading.confirmSource)
    }

    func test_malformed_json_throws() {
        XCTAssertThrowsError(try GeoResponses.decodeIPInfo(Data("не json".utf8)))
    }

    func test_ipinfo_without_optional_fields_still_decodes() throws {
        let minimal = Data(#"{"ip":"1.2.3.4","country_code":"DE"}"#.utf8)
        let response = try GeoResponses.decodeIPInfo(minimal)
        XCTAssertEqual(response.ip, "1.2.3.4")
        XCTAssertEqual(response.countryCode, "DE")
    }
}
