# Geo whitelist (allowed exits)

## Goal
Let the owner narrow the guard: an optional list of countries and IP/CIDR ranges that the
VPN exit is allowed to be. Until now only the opposite existed — a blacklist that named the
exits to run away from. A blacklist cannot express "only NL and DE are fine": every country
the owner never thought of stayed implicitly safe.

The list is optional and empty by default, so nothing changes for anyone who does not fill it
in — including settings written by previous versions.

## Scope
Both platforms, all four layers: policy core, settings storage, settings UI, shared fixtures.

- macOS: `WetoCore/GuardPolicy.swift`, `WetoCore/Model/KillEvent.swift`,
  `WetoShared/SettingsStore.swift`, `WetoMenuBar/Settings/GeoListCard.swift`,
  `WetoMenuBar/Settings/SettingsWindow.swift`
- Linux: `weto-core/src/policy.rs`, `weto-core/src/presentation.rs`,
  `weto-config/src/settings.rs`, `weto-app/src/settings_window.rs`
- Shared: `shared/fixtures/guard-policy.json`

## Changes
- Added: `GuardConfig.allowedCountries` / `allowedIPRanges` (`allowed_countries` /
  `allowed_ip_ranges`) plus `hasWhitelist` / `has_whitelist`.
- Added: `UnsafeReason.notWhitelistedIP` / `.notWhitelistedCountry`
  (`NotWhitelistedIp` / `NotWhitelistedCountry`) with wording identical on both platforms —
  «Адрес {ip} не входит в белый список», «Страна {code} не входит в белый список».
- Added: a whitelist stage in `decide`, **after** the country-conflict check. Empty list → safe;
  IP inside an allowed CIDR → safe; agreed country in the allowed set → safe; otherwise kill.
- Added: `UserDefaults` keys `allowedCountryCodes` / `allowedIPRangeTexts` and TOML keys
  `allowed_countries` / `allowed_ip_ranges` (`serde(default)`). Absent keys = empty whitelist,
  so old settings keep their exact previous behaviour.
- Added: `GuardConfigurationChange.Field.whitelist` — editing the list bumps the config
  revision and therefore invalidates the standing verdict, same as the blacklist.
- Modified: entry parsing / duplicate check / removal became one path per platform, taken by
  `GeoListKind` — `addEntry(_:to:)`, `removeEntry(_:from:)`, `entries(of:)`
  (`add_entry`, `remove_entry`, `entries`). The `…Blocked…` functions survive as thin
  delegating wrappers. `BlacklistEntryError` → `GeoListEntryError` on both platforms.
- Modified: `BlacklistCard.swift` → `GeoListCard.swift`, one parameterised card built twice;
  Linux `blacklist_card` → `geo_list_card(state, kind, title)`, also built twice. The macOS
  settings screen and the Linux one both show six cards now.
- Modified: `shared/fixtures/guard-policy.json` → `version: 3`, 28 → 36 cases. Both runners
  read `allowedCountries` / `allowedIPRanges` as optional, so the pre-existing cases are
  untouched.

## Risks
- **The whitelist stage sits last on purpose.** Moving it earlier (in particular ahead of
  `confirmationUnavailable` or `countryConflict`) would let an allowed country cancel the
  strict fail-closed rules — a compile-clean change that quietly weakens the product.
- The list only ever narrows: a non-empty whitelist that nobody matched kills targets on an
  otherwise perfectly healthy VPN. That is the intended meaning, and the reason wording has to
  make it obvious, otherwise it reads as a bug in the geo probe.
- Both platforms parse entries in duplicated-by-language code; the shared fixtures are the
  only mechanism that catches a drift between them.

## How to test
- [ ] Empty whitelist: previously safe cases stay safe (both fixture runners cover this).
- [ ] Add the current exit's country → still safe; add a foreign one only → targets die with
      «Страна … не входит в белый список».
- [ ] Add a CIDR covering the current exit → safe even though the country is not listed.
- [ ] Put one country into both lists → the blacklist wins, reason is the blacklist one.
- [ ] Editing the whitelist while safe re-arms verification (`GuardVMTests`,
      `weto-guard/tests/controller.rs`).
- [ ] Open settings written by the previous version → whitelist card is empty, behaviour
      unchanged.

## Related modules
- modules/weto-core.md
- modules/weto-shared.md
- modules/weto-menubar.md
- modules/linux-guard.md
