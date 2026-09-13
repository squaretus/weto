import XCTest
@testable import WetoCore

final class GuardPolicyTests: XCTestCase {

    private func config(
        vpn: String? = "BC2D1D42",
        blocked: Set<String> = ["RU"],
        ranges: [IPRange] = [],
        allowed: Set<String> = [],
        allowedRanges: [IPRange] = [],
        targets: [String] = ["com.example.target"]
    ) -> GuardConfig {
        GuardConfig(
            vpnAppRule: vpn,
            blockedCountries: blocked,
            blockedIPRanges: ranges,
            allowedCountries: allowed,
            allowedIPRanges: allowedRanges,
            targets: targets
        )
    }

    private func geo(
        ip: String = "203.0.113.28",
        primary: String = "KZ",
        confirmed: String? = "KZ",
        source: ConfirmSource? = .freeipapi
    ) -> GeoOutcome {
        .resolved(GeoReading(
            ip: ip,
            primaryCountry: primary,
            confirmedCountry: confirmed,
            confirmSource: source
        ))
    }

    private func signals(
        enabled: Bool = true,
        vpn: VPNAppStatus = .running,
        geo geoOutcome: GeoOutcome? = nil,
        config configuration: GuardConfig? = nil
    ) -> GuardSignals {
        GuardSignals(
            isEnabled: enabled,
            vpn: vpn,
            geo: geoOutcome ?? geo(),
            config: configuration ?? config()
        )
    }

    /// `degraded` — «ipinfo молчит, но адрес доказанно тот же». Прошлое чтение
    /// прогоняется через все те же проверки: адрес не менялся, значит и страна та же,
    /// а вот чёрный список и блокировка стран обязаны работать без поблажек.
    func test_degraded_reading_passes_the_same_checks() {
        let previous = GeoReading(
            ip: "203.0.113.28",
            primaryCountry: "KZ",
            confirmedCountry: "KZ",
            confirmSource: .freeipapi
        )

        XCTAssertEqual(
            GuardPolicy.decide(signals(geo: .degraded(previous: previous, detail: "ipinfo молчит"))),
            .safe
        )
    }

    func test_degraded_reading_with_blocked_country_still_kills() {
        let previous = GeoReading(
            ip: "203.0.113.28",
            primaryCountry: "RU",
            confirmedCountry: "RU",
            confirmSource: .freeipapi
        )

        XCTAssertEqual(
            GuardPolicy.decide(signals(geo: .degraded(previous: previous, detail: "ipinfo молчит"))),
            .kill(.blockedCountry(code: "RU", source: "ipinfo"))
        )
    }

    func test_everything_aligned_is_safe() {
        XCTAssertEqual(GuardPolicy.decide(signals()), .safe)
    }

    func test_disabled_guard_is_always_safe_even_with_blocked_country() {
        let s = signals(enabled: false, vpn: .notRunning, geo: geo(primary: "RU", confirmed: "RU"))
        XCTAssertEqual(GuardPolicy.decide(s), .safe)
    }

    func test_empty_target_list_is_safe() {
        let s = signals(vpn: .notRunning, config: config(targets: []))
        XCTAssertEqual(GuardPolicy.decide(s), .safe)
    }

    func test_a_closed_vpn_app_kills() {
        XCTAssertEqual(GuardPolicy.decide(signals(vpn: .notRunning)), .kill(.vpnAppNotRunning))
    }

    func test_the_app_check_precedes_the_geo_check() {

        let s = signals(vpn: .notRunning, geo: .unavailable("timeout"))
        XCTAssertEqual(GuardPolicy.decide(s), .kill(.vpnAppNotRunning))
    }

    func test_geo_unavailable_is_unproven_with_reason_text() {
        let s = signals(geo: .unavailable("timeout"))
        XCTAssertEqual(GuardPolicy.decide(s), .unproven(.geoUnavailable("timeout")))
    }

    func test_blacklisted_ip_kills_even_when_country_is_allowed() {
        let s = signals(
            geo: geo(ip: "198.51.100.231", primary: "KZ", confirmed: "KZ"),
            config: config(ranges: [IPRange("198.51.100.0/22")!])
        )
        XCTAssertEqual(GuardPolicy.decide(s), .kill(.blacklistedIP("198.51.100.231")))
    }

    func test_blacklist_precedes_country_check() {

        let s = signals(
            geo: geo(ip: "198.51.100.231", primary: "RU", confirmed: "RU"),
            config: config(ranges: [IPRange("198.51.100.231")!])
        )
        XCTAssertEqual(GuardPolicy.decide(s), .kill(.blacklistedIP("198.51.100.231")))
    }

    func test_ip_outside_all_ranges_does_not_trigger_blacklist() {
        let s = signals(config: config(ranges: [IPRange("10.0.0.0/8")!]))
        XCTAssertEqual(GuardPolicy.decide(s), .safe)
    }

    func test_blocked_primary_country_kills() {
        let s = signals(geo: geo(primary: "RU", confirmed: "RU"))
        XCTAssertEqual(
            GuardPolicy.decide(s),
            .kill(.blockedCountry(code: "RU", source: "ipinfo"))
        )
    }

    func test_blocked_confirmed_country_kills_even_when_primary_is_allowed() {
        let s = signals(geo: geo(primary: "KZ", confirmed: "RU", source: .freeipapi))
        XCTAssertEqual(
            GuardPolicy.decide(s),
            .kill(.blockedCountry(code: "RU", source: "freeipapi"))
        )
    }

    func test_country_comparison_is_case_insensitive() {
        let s = signals(
            geo: geo(primary: "ru", confirmed: "ru"),
            config: config(blocked: ["RU"])
        )
        XCTAssertEqual(
            GuardPolicy.decide(s),
            .kill(.blockedCountry(code: "RU", source: "ipinfo"))
        )
    }

    func test_missing_confirmation_is_unproven_even_when_ipinfo_says_allowed_country() {

        let s = signals(geo: geo(primary: "KZ", confirmed: nil, source: nil))
        XCTAssertEqual(GuardPolicy.decide(s), .unproven(.confirmationUnavailable))
    }

    func test_blocked_primary_country_precedes_missing_confirmation() {
        let s = signals(geo: geo(primary: "RU", confirmed: nil, source: nil))
        XCTAssertEqual(
            GuardPolicy.decide(s),
            .kill(.blockedCountry(code: "RU", source: "ipinfo"))
        )
    }

    func test_country_conflict_kills() {
        let s = signals(geo: geo(primary: "KZ", confirmed: "DE"))
        XCTAssertEqual(
            GuardPolicy.decide(s),
            .kill(.countryConflict(primary: "KZ", confirmed: "DE"))
        )
    }

    func test_matching_countries_in_different_case_are_not_a_conflict() {
        let s = signals(geo: geo(primary: "KZ", confirmed: "kz"))
        XCTAssertEqual(GuardPolicy.decide(s), .safe)
    }

    // MARK: - Три исхода: safe / unproven / kill

    /// Без ответа ipinfo нет ни доказательства утечки, ни доказательства защиты.
    func test_silent_ipinfo_is_unproven_not_a_kill() {
        let signals = GuardSignals(isEnabled: true, vpn: .running,
                                   geo: .unavailable("таймаут запроса"), config: config())
        XCTAssertEqual(GuardPolicy.decide(signals), .unproven(.geoUnavailable("таймаут запроса")))
    }

    func test_missing_confirmation_is_unproven() {
        let reading = GeoReading(ip: "203.0.113.28", primaryCountry: "KZ", confirmedCountry: nil, confirmSource: nil)
        let signals = GuardSignals(isEnabled: true, vpn: .running, geo: .resolved(reading), config: config())
        XCTAssertEqual(GuardPolicy.decide(signals), .unproven(.confirmationUnavailable))
    }

    /// Резервный сервис назвал другой адрес: страна не проверена, но и утечка не доказана.
    func test_changed_address_is_unproven() {
        let previous = GeoReading(ip: "203.0.113.28", primaryCountry: "KZ", confirmedCountry: "KZ", confirmSource: .freeipapi)
        let signals = GuardSignals(isEnabled: true, vpn: .running,
                                   geo: .addressChanged(observed: "198.51.100.7", previous: previous), config: config())
        XCTAssertEqual(GuardPolicy.decide(signals), .unproven(.addressChanged(observed: "198.51.100.7")))
    }

    func test_blocked_country_is_still_a_kill() {
        let reading = GeoReading(ip: "203.0.113.28", primaryCountry: "RU", confirmedCountry: "RU", confirmSource: .freeipapi)
        let signals = GuardSignals(isEnabled: true, vpn: .running, geo: .resolved(reading), config: config())
        XCTAssertEqual(GuardPolicy.decide(signals), .kill(.blockedCountry(code: "RU", source: "ipinfo")))
    }

    /// Невыбранное VPN-приложение — не причина: охрана работает по гео одной.
    func test_unchosen_vpn_app_leaves_the_decision_to_geo() {
        let unchosenConfig = config(vpn: nil)
        let reading = GeoReading(ip: "203.0.113.28", primaryCountry: "KZ", confirmedCountry: "KZ", confirmSource: .freeipapi)
        XCTAssertEqual(
            GuardPolicy.decide(GuardSignals(isEnabled: true, vpn: .notChosen, geo: .resolved(reading), config: unchosenConfig)),
            .safe
        )
    }

    // MARK: - Белый список

    /// Пустой whitelist — умолчание всех существующих установок: поведение
    /// обязано остаться ровно прежним.
    func test_empty_whitelist_leaves_the_safe_case_safe() {
        XCTAssertEqual(GuardPolicy.decide(signals()), .safe)
    }

    func test_allowed_country_lets_the_exit_through() {
        XCTAssertEqual(
            GuardPolicy.decide(signals(config: config(allowed: ["KZ"]))),
            .safe
        )
    }

    /// Регистр в настройках не нормализован задним числом: политика приводит сама.
    func test_allowed_country_is_matched_case_insensitively() {
        XCTAssertEqual(
            GuardPolicy.decide(signals(config: config(allowed: ["kz"]))),
            .safe
        )
    }

    func test_allowed_cidr_lets_the_exit_through() {
        XCTAssertEqual(
            GuardPolicy.decide(signals(
                config: config(allowedRanges: [IPRange("203.0.113.0/24")!])
            )),
            .safe
        )
    }

    /// Совпадение по IP достаточно само по себе: страна в разрешённых не нужна.
    func test_allowed_cidr_wins_even_when_the_country_is_not_allowed() {
        XCTAssertEqual(
            GuardPolicy.decide(signals(
                config: config(allowed: ["DE"], allowedRanges: [IPRange("203.0.113.0/24")!])
            )),
            .safe
        )
    }

    func test_country_outside_a_country_only_whitelist_kills() {
        XCTAssertEqual(
            GuardPolicy.decide(signals(config: config(allowed: ["DE"]))),
            .kill(.notWhitelistedCountry("KZ"))
        )
    }

    /// Диагностический приоритет у IP: если в списке есть диапазоны и адрес
    /// в них не попал, пользователю называют именно адрес.
    func test_address_outside_a_whitelist_with_ranges_names_the_address() {
        XCTAssertEqual(
            GuardPolicy.decide(signals(
                config: config(allowed: ["DE"], allowedRanges: [IPRange("198.51.100.0/24")!])
            )),
            .kill(.notWhitelistedIP("203.0.113.28"))
        )
    }

    /// Одна и та же запись в обоих списках — не ошибка ввода: приоритет у чёрного.
    func test_blacklisted_country_wins_over_the_same_country_in_the_whitelist() {
        XCTAssertEqual(
            GuardPolicy.decide(signals(
                config: config(blocked: ["KZ"], allowed: ["KZ"])
            )),
            .kill(.blockedCountry(code: "KZ", source: "ipinfo"))
        )
    }

    func test_blacklisted_range_wins_over_the_same_range_in_the_whitelist() {
        XCTAssertEqual(
            GuardPolicy.decide(signals(
                config: config(
                    ranges: [IPRange("203.0.113.0/24")!],
                    allowedRanges: [IPRange("203.0.113.0/24")!]
                )
            )),
            .kill(.blacklistedIP("203.0.113.28"))
        )
    }

    /// Отсутствие подтверждения решает раньше whitelist — иначе строгий
    /// fail-closed превратился бы в «нам хватило разрешённой страны».
    func test_missing_confirmation_is_unproven_before_the_whitelist_is_consulted() {
        XCTAssertEqual(
            GuardPolicy.decide(signals(
                geo: geo(confirmed: nil, source: nil),
                config: config(allowed: ["KZ"])
            )),
            .unproven(.confirmationUnavailable)
        )
    }

    func test_country_conflict_kills_before_the_whitelist_is_consulted() {
        XCTAssertEqual(
            GuardPolicy.decide(signals(
                geo: geo(primary: "KZ", confirmed: "DE"),
                config: config(allowed: ["KZ"])
            )),
            .kill(.countryConflict(primary: "KZ", confirmed: "DE"))
        )
    }
}
