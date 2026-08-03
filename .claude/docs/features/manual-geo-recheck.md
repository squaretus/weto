# Feature: manual geo recheck from the popup

## Problem

When ipinfo or the confirming service went silent, the popup said "Ipinfo недоступен" and
blanked every data line to `—`. The reason string travelled to the journal only, and the next
probe was whenever the poll loop felt like it. From the user's chair: corporate targets are
being killed, nothing explains why, and there is no way to ask the app to check right now.

## What the user sees

Header of the status popup, left of the gear: an `arrow.clockwise` icon button
(`WetoIconButtonStyle`), replaced by a small `ProgressView` while the request is in flight.
The data block always reflects the last probe, whoever started it:

| everything answered | ipinfo silent |
|---|---|
| `IP: 188.32.11.4` | `ipinfo: таймаут запроса` |
| `ipinfo: NL` | `подтверждение: не запрашивалось` |
| `freeipapi: NL` | `сеть: есть` |
| `Проверено: 12:41:07` | `Проверено: 12:41:07` |

The `сеть` line appears only when something failed, and it is the cheapest answer the system
can give: `NWPathMonitor.currentPath`, no extra request. The confirmation row is labelled with
the service that actually answered (`freeipapi` / `geojs`), or `подтверждение` when none did.

## How it works

- `GeoProbing.probe()` returns a `GeoProbeReport` (WetoCore): `ip`, per-source outcome
  (`answered` / `failed(GeoFailure)` / `notRequested`), `confirmSource`, `hasNetworkPath`,
  `checkedAt`. The guard verdict is `report.outcome`, so screen and enforcement can never
  disagree — there is one object behind both.
- `GeoFailure` turns numbers into wording: `noNetwork`, `unreachable`, `timedOut`,
  `unauthorized(401/403)`, `rateLimited(429)`, `serviceError(5xx)`, and `other(String)` as the
  deliberate escape hatch — an unmapped code shows the system's own text rather than being
  silently filed as "no network". Classification lives in WetoCore; `WetoSystem` only hands it
  the HTTP status or `URLError` code, so the purity invariant holds.
- `GuardVM.recheckNow()` → `GuardController.probeNow()`: no debounce, no `freshVerdict` reset,
  result applied through the usual path. `isProbing` gates repeat presses.
- `StatusPresentation.lines(for:report:timeZone:)` renders the block; the old
  `lines(for:reading:)` still serves the cold start, before any probe exists.

## Tests
- `Tests/WetoCoreTests/GeoFailureTests.swift` — status/code → wording, including the fallback
- `Tests/WetoCoreTests/GeoProbeReportTests.swift` — report → verdict
- `Tests/WetoSystemTests/GeoProbeTests.swift` — report contents, refused confirmation keeps its reason
- `Tests/WetoSharedTests/GuardVMTests.swift` — recheck does not kill on a healthy VPN, lifts the
  block when the service answers again, one request per press, report kept for the popup
- `Tests/WetoSharedTests/StatusPresentationTests.swift` — both line layouts

## Related
- `.claude/docs/decisions/geo-confirmation-services.md` — why these services, and the quotas
- `.claude/docs/modules/weto-shared.md`, `weto-system.md`, `weto-core.md`
