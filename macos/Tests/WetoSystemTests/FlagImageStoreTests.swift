import XCTest
import AppKit
@testable import WetoSystem
import WetoDesign

/// Флаги лежат в бандле, а не тянутся из сети.
///
/// Сеть на этом пути была вредна дважды: `cdn.jsdelivr.net` в России блокируется,
/// а флаг показывается ровно тогда, когда пользователь под VPN — и до CDN может
/// не дойти. Вдобавок загрузка ничего не будила, и картинка появлялась только
/// при следующей смене состояния: у пользователя флаг лежал в кэше и не показывался.
final class FlagImageStoreTests: XCTestCase {

    func test_flags_are_found_for_the_countries_users_actually_see() {
        let store = FlagImageStore()

        for code in ["ru", "kz", "at", "nl", "de", "us", "tr", "rs", "am", "ge"] {
            XCTAssertNotNil(store.image(for: code), "нет флага для «\(code)»")
        }
    }

    func test_the_code_is_case_insensitive() {
        XCTAssertNotNil(FlagImageStore().image(for: "AT"))
    }

    func test_garbage_codes_yield_nothing() {
        let store = FlagImageStore()

        XCTAssertNil(store.image(for: ""))
        XCTAssertNil(store.image(for: "rus"))
        XCTAssertNil(store.image(for: "..")) 
        XCTAssertNil(store.image(for: "/etc/passwd"))
    }

    /// Набор обязан покрывать все двухбуквенные коды, которые вообще может назвать
    /// гео-сервис: пропуск виден не в тесте, а пустым значком в менюбаре.
    func test_every_iso_country_code_has_a_flag() throws {
        // EZ (еврозона) и QO (внешняя Океания) — не страны, а группировки
        // из служебной части списка: гео-сервис их не называет, и флага у них нет.
        let notCountries: Set<String> = ["EZ", "QO"]

        let missing = Locale.Region.isoRegions
            .map(\.identifier)
            .filter { $0.count == 2 && !notCountries.contains($0) }
            .filter { DesignResources.flagURL(forCountry: $0) == nil }

        XCTAssertTrue(missing.isEmpty, "нет флагов для: \(missing.sorted().joined(separator: ", "))")
    }
}
