import XCTest
@testable import WetoCore

final class VPNPickerTests: XCTestCase {

    private let happ = NetworkServiceSnapshot(
        uuid: "BC2D1D42", name: "Happ", activeInterface: "utun6", isVPN: true
    )

    func test_the_first_row_is_always_not_selected() {
        let rows = VPNPicker.rows(candidates: [], chosen: nil)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "")
        XCTAssertEqual(rows[0].label, "Не выбран")
    }

    /// Интерфейс клиента, поднимающего туннель самостоятельно, существует ровно
    /// пока живо подключение. Выбор обязан пережить его исчезновение, иначе
    /// пользователь видит пустую строку вместо своего туннеля.
    func test_a_chosen_tunnel_stays_in_the_list_after_it_disappears() {
        let rows = VPNPicker.rows(candidates: [], chosen: "interface:utun7")

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1].id, "interface:utun7")
        XCTAssertEqual(rows[1].label, "utun7 (не подключён)")
    }

    func test_a_present_choice_is_not_duplicated() {
        let rows = VPNPicker.rows(candidates: [happ], chosen: happ.uuid)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.filter { $0.id == happ.uuid }.count, 1)
        XCTAssertEqual(rows[1].label, "Happ")
    }

    /// Имени у отключённого сервиса взять неоткуда, и остаётся показать
    /// сам идентификатор — врать выдуманным названием нельзя.
    func test_a_missing_service_falls_back_to_its_identifier() {
        let rows = VPNPicker.rows(candidates: [], chosen: "BC2D1D42")
        XCTAssertEqual(rows[1].label, "BC2D1D42 (не подключён)")
    }

    func test_an_empty_choice_adds_nothing() {
        XCTAssertEqual(VPNPicker.rows(candidates: [happ], chosen: "").count, 2)
    }
}
