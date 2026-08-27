# WetoCore

## Purpose
Pure decision core of the kill switch: given a config, a network snapshot, a geo reading and a
process list, it decides whether targets must die and which pids to kill. It owns no I/O, so the
bulk of the project's tests stay synchronous and mock-free. Everything that talks to macOS lives
in `WetoSystem`; everything that holds state lives in `WetoShared`.

## Key files
- `macos/Sources/WetoCore/GuardPolicy.swift` — `GuardConfig`, `GuardSignals`, `UnsafeReason`, `GuardDecision`, the three decision entry points
- `macos/Sources/WetoCore/ProcessMatcher.swift` — rules × processes → pids to kill / rows to show
- `macos/Sources/WetoCore/ProcessTree.swift` — parent/child index shared by both matcher passes
- `macos/Sources/WetoCore/IPAddress.swift`, `IPRange.swift` — `inet_pton` parsing, CIDR containment
- `macos/Sources/WetoCore/GeoResponses.swift` — DTOs and decoding for ipinfo / freeipapi / geojs
- `macos/Sources/WetoCore/GeoFailure.swift` — HTTP status / `URLError` code → wording shown to the user
- `macos/Sources/WetoCore/VoidResult.swift`, `Constants.swift`
- `macos/Sources/WetoCore/Model/` — `GeoModels`, `GeoProbeReport`, `NetworkSnapshot`, `ProcessSnapshot`, `TargetRule`, `KillEvent`
- Tests: `macos/Tests/WetoCoreTests/` (~100 cases; `ProcessMatcherTests` and `GuardPolicyTests` are the load-bearing ones)

## Entry points
- `GuardPolicy.decideLocal(isEnabled:vpn:config:) → GuardDecision?` — tri-state, see invariants; `vpn` is a `VPNAppStatus`, computed by the caller from the process scan
- `GuardPolicy.decide(GuardSignals) → GuardDecision` — full ordered chain
- `GuardPolicy.pendingVerification(isEnabled:config:) → GuardDecision`
- `GuardConfig.hasTargets`, `GuardConfig.hasWhitelist` — the whitelist stage is skipped entirely
  when the latter is `false`
- `ProcessMatcher.matches(in:rules:) → [MatchedProcess]`, `.pids(in:rules:) → [Int32]`
- `ProcessMatcher.runningTargets(in:rules:) → [RunningTarget]` — UI rows, one per session
- `NetworkSnapshot.verdictFingerprint → String` — the interface carrying the verdict request plus its local address, nothing else
- `IPAddress.isValid(_:)`, `IPRange.init?(_:)`, `IPRange.contains(_:)`
- `GeoResponses.decodeIPInfo/decodeFreeIPAPI/decodeGeoJS/makeReading`
- `ReleaseParser.parse(_:currentVersion:) → Result<UpdateInfo, Error>`, `ReleaseParser.latestReleaseURL`
- `UnsafeReason.displayText / statusTitle / isDegradedRatherThanBlocked` — user-facing wording lives here, not in the views
- `Result<Void, _>.isSuccess / .failureValue`
- `ProcessTree` is `public` but has no call site outside `ProcessMatcher`

## Dependencies
- Package deps: none. `macos/Package.swift` declares `.target(name: "WetoCore")` with an empty dependency list.
- Imports: `Foundation` only, plus `Darwin` in `IPAddress.swift` and `IPRange.swift` for `inet_pton`.
- Service / DB / queue / external API: none — the module never performs a request or a write.
- Consumers: `WetoSystem` (`GeoProbe`, `ProcessRegistry`, `TargetResolver`, `NetworkSnapshotReader`),
  `WetoShared` (`GuardController`, `ProcessEnforcer`, `GuardVM`, `SettingsStore`),
  `WetoMenuBar`, `WetoHelper` (entry point only). Release parsing, versions and the download
  host allow-list moved to `UpdateKitCore` — see `modules/update-kit.md`.

## Side effects
<!-- generated, verify -->
- None by design; every public function is `static` and pure over its arguments.
- One exception: `Constants.appVersion` is a lazy `static let` that reads `Bundle.main.bundleIdentifier`
  and `CFBundleShortVersionString` on first access, and caches the result for the process lifetime.
  It is the only host-environment read in the module and yields `"dev"` whenever `Bundle.main` is not
  the `com.weto.app` bundle (i.e. under `swift test` and `swift run`).
- `GeoResponses` keeps a single shared `JSONDecoder` instance; it is stateless in current use but is
  not `Sendable`-annotated shared state to add configuration to.

## Invariants / assumptions
<!-- generated, verify -->
- **No system frameworks.** `Network`, `SystemConfiguration`, `AppKit`, `SwiftUI` and `URLSession`
  must never appear here. Every model type is a `Sendable` value type, so decisions can be computed
  off the main actor and compared in tests without mocks. Breaking this is the project's most
  expensive mistake.
- **`decideLocal` is tri-state and `nil` is not safe.** `nil` means "no local grounds, a network
  verdict is required"; `.safe` is returned only when the guard is off or no targets are configured.
  `GuardController` depends on that distinction — a caller that coalesces `nil` into `.safe` disables
  the whole geo half of the policy.
- **All three entry points re-check `isEnabled && config.hasTargets` first.** That guard is what makes
  a disabled switch inert; it is duplicated on purpose in `decide`, `decideLocal` and `pendingVerification`.
- **Country comparison is case-insensitive at compare time**, not at storage time: both the blocked
  and the allowed sets, and the readings, are uppercased inside `decide`, so persisted settings may
  hold any casing.
- **The whitelist narrows, it never rescues.** It is asked last and only of an already agreed
  verdict: an empty list returns `.safe` unchanged, and a non-empty one demands the address be
  inside an allowed CIDR *or* the agreed country be in the allowed set. Blacklist, missing
  confirmation and country conflict all decide earlier by design — an allowed country must not be
  able to cancel strict fail-closed. Consequence: the same country in both lists is not a data
  entry error, the blacklist simply wins.
- **The whitelist reason is a diagnostic choice, not a decision.** `notWhitelistedIP` is reported
  when the list contains any ranges, `notWhitelistedCountry` when it is countries only. Both mean
  the same kill; swapping them changes only the sentence the user reads.
- **Rule order is significant.** `matches` uses `rules.first(where:)` and `runningTargets` uses
  `rules.firstIndex(where:)`, so the earliest matching rule names the process and owns the UI row.
- **`TargetRule.launchPaths` always starts with `path`** — the initializer prepends it and de-duplicates,
  so a rule built with an empty `launchPaths` still matches its own path.
- **Matching semantics per kind:** `appBundle` compares an `executablePath` prefix with an appended
  `"/"` (so sibling bundles sharing a name prefix do not match, and a trailing slash in the stored
  path is tolerated); `binary` compares full-path equality against `launchPaths`; `script` requires an
  exact equality with one `argv` element — never a substring, and never the interpreter path.
- **Cycles in the process tree are assumed possible.** `ProcessTree.descendants` relies on a shared
  `seen` set plus `stepLimit = processes.count * 2`, and `topmostMatch` is bounded by the pid count.
  A snapshot where a parent points at its own descendant must terminate, not hang.
- **`verdictFingerprint` covers the traffic carrier and nothing else:** the interface the kernel
  picks for the verdict request plus that interface's local address. The address is in there because
  a tunnel can keep its name and change its address — that is a different network state. The set of
  interfaces is deliberately absent: a second VPN reconnecting on its own used to change the
  machine-wide fingerprint and kill targets with `verificationPending` while the traffic never moved.
  `out=-` (no carrier, or the geo host not resolved yet) is its own state, and a verdict cannot
  exist in it.
- **`VPNAppStatus` is the caller's answer, not the core's.** The core never scans processes; it only
  knows whether something was chosen (`config.vpnAppRule`) and what the caller reports. `decideLocal`
  kills on an empty selection *before* looking at the status, so a caller whose status drifts out of
  sync with the settings still fails closed.
- **`ProcessSnapshot.arguments` stays an array.** A joined command line must never be used for matching.

## Failure hotspots
<!-- generated, verify -->
- **The check order in `GuardPolicy.decide` is the security contract**, not a style choice: blacklist
  before country, primary country before `confirmationUnavailable`, `countryConflict` before the
  whitelist stage, which is last of all. Reordering compiles, keeps most tests green and silently
  weakens fail-closed. The canonical order is in
  `.claude/rules/ARCHITECTURE.md` → "Инварианты, общие для обеих реализаций".
- **`decide` has an unreachable branch:** the `geoUnavailable("нет данных")` fallback can only fire if
  `GeoOutcome` gains a third case. Adding one routes it into a generic reason instead of a compile error.
- **`GeoFailure.other` is load-bearing, not a leftover:** it is the escape hatch for codes the
  classifier does not know. Replacing it with a fixed wording would present an unknown failure
  as a known one — the popup would say "нет сети" about a certificate error.
- **`matches` and `runningTargets` implement root selection and de-duplication separately** and share
  only `ProcessTree`. A fix applied to one (session ownership, child counting, app-bundle collapsing)
  is easy to forget in the other; both have dedicated cycle tests for that reason.
- **`runningTargets` merges `appBundle` rows by `entry`.** Two rules pointing at the same entry with a
  different `kind`, or the same app reached through two different entries, will not collapse into one row.
- **`Constants.appVersion == "dev"` outside the app bundle** makes `ReleaseParser.parse` (now in
  `UpdateKitCore`) fail with `invalidVersion`. This is why `UpdateController` takes the current
  version as a parameter instead of reading the constant directly; a new caller that reads it will
  "work" in the app and fail in tests.
- **`WetoUpdate.configuration` is the single place that names the repository and the daemon.**
  `Constants.githubRepoURL` is derived from it; a second copy of those strings is a bug.
- **`IPRange.contains` returns `false` for a family mismatch or unparsable input.** Errors are absent
  by design: an entry that survived `IPRange.init?` but is compared against the wrong family simply
  never matches, and no reason surfaces to the user.

## Related docs
- Map and cross-module contracts: `.claude/rules/ARCHITECTURE.md` (check order, fail-closed rules,
  VPN qualification, script-vs-argv matching)
- Project pitfalls that shape this module (symlinked binaries, shebang scripts, GUI-only workspace
  notifications): `.claude/CLAUDE.md` → "Ловушки предметной области"
- `features/geo-whitelist.md` — the optional allowed-exits list and where its stage sits
- `bugs/`, `decisions/` — no entries beyond `decisions/vpn-app-instead-of-tunnel.md`,
  `decisions/geo-confirmation-services.md`
