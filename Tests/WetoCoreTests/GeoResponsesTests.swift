import XCTest
@testable import WetoCore

final class GeoResponsesTests: XCTestCase {

    private let ipinfoJSON = Data("""
    {"ip":"203.0.113.28","asn":"AS49791","as_name":"Newserverlife LLC",
     "as_domain":"3hcloud.com","country_code":"KZ","country":"Kazakhstan",
     "continent_code":"AS","continent":"Asia"}
    """.utf8)

    private let ipwhoisJSON = Data("""
    {"ip":"203.0.113.28","success":true,"type":"IPv4","continent":"Asia",
     "continent_code":"AS","country":"Kazakhstan","country_code":"KZ",
     "region":"Almaty","city":"Almaty","is_eu":false,
     "connection":{"asn":49791,"org":"3hcloud LLC","isp":"Newserverlife LLC",
     "domain":"3hcloud.com"}}
    """.utf8)

    private let geojsJSON = Data("""
    {"country":"KZ","country_3":"KAZ","ip":"203.0.113.28","name":"Kazakhstan"}
    """.utf8)

    func test_ipinfo_response_is_decoded() throws {
        let response = try GeoResponses.decodeIPInfo(ipinfoJSON)
        XCTAssertEqual(response.ip, "203.0.113.28")
        XCTAssertEqual(response.countryCode, "KZ")
        XCTAssertEqual(response.asn, "AS49791")
    }

    func test_ipwhois_response_yields_country_code() throws {
        XCTAssertEqual(try GeoResponses.decodeIPWhoIs(ipwhoisJSON), "KZ")
    }

    func test_ipwhois_failure_response_yields_nil() throws {

        let failure = Data(#"{"ip":"1.1.1.1","success":false,"message":"Invalid IP"}"#.utf8)
        XCTAssertNil(try GeoResponses.decodeIPWhoIs(failure))
    }

    func test_geojs_response_yields_country_code() throws {
        XCTAssertEqual(try GeoResponses.decodeGeoJS(geojsJSON), "KZ")
    }

    func test_reading_is_assembled_from_ipinfo_and_confirmation() throws {
        let response = try GeoResponses.decodeIPInfo(ipinfoJSON)
        let reading = GeoResponses.makeReading(
            ipinfo: response,
            confirmedCountry: "KZ",
            source: .ipwhois
        )
        XCTAssertEqual(reading.ip, "203.0.113.28")
        XCTAssertEqual(reading.asn, "AS49791")
        XCTAssertEqual(reading.primaryCountry, "KZ")
        XCTAssertEqual(reading.confirmedCountry, "KZ")
        XCTAssertEqual(reading.confirmSource, .ipwhois)
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
        XCTAssertNil(response.asn)
    }
}
