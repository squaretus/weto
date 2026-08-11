# Decision: which geo services confirm the country, and why no cache

## Context

The guard needs two independent answers about the same public address: which IP we are
seen as, and which country that IP is in. A wrong or stale country answer is not a cosmetic
bug — it either kills the user's targets on a healthy VPN, or leaves them running while the
traffic is already leaking. Rate limits matter more than usual: every user behind one VPN
exit shares that exit's address, so per-client-IP quotas are effectively per-VPN quotas.

## Decision

- **IP source: ipinfo only** (`v4.api.ipinfo.io`, Lite tier — no request limit). Other
  services answer about a *different* address under split routing, which is why they are
  asked about the already-known IP instead of "my" IP.
- **Confirmation: `free.freeipapi.com`, falling back to `get.geojs.io`.**
- **No cache anywhere on this path.** Confirmation is requested on every probe.

## Why these, measured rather than assumed

| Service | Limit | Verdict |
|---|---|---|
| ipinfo Lite | none declared | IP source |
| `free.freeipapi.com` | 60 requests/minute — our spend is 12 | primary confirmation |
| `get.geojs.io` | no declared limit | fallback |
| `ipwho.is` | 1000/day **per client IP** | rejected: burned out in ~1.4 h behind one VPN exit |
| `ipquery.io` | — | rejected: stale registration data on reassigned ranges |
| `ifconfig.co` | — | rejected: same, gives a false country mismatch |

The last two are the subtle ones: on reassigned address ranges they report the country from
outdated registration records. Against a correct answer from the other service that reads as
"the services disagree", which is a kill reason — so a bad confirmer does not fail safe, it
fails loud and wrong.

## Consequences

- A cache would mean a country change on an unchanged address goes unnoticed until it
  expires. For a kill switch that is the whole failure mode, so caching is refused at every
  level: ephemeral session config, `urlCache = nil`, and
  `reloadIgnoringLocalAndRemoteCacheData` on both the configuration and each request.
- Confirmation gets its own fetcher with a shorter timeout
  (`Constants.geoConfirmationTimeoutSeconds`), so a slow confirmer does not stall the probe.
- Adding a third confirmer means re-measuring, not just appending a URL: the limit has to
  hold at our per-probe rate, and the data has to be accurate on reassigned ranges.

- Without an ipinfo token the probe has no IP to ask about, and until this was addressed it
  returned "no token" without touching the network — a fresh install could not answer "where
  am I" at all. `get.geojs.io/v1/ip/country.json` answers about the caller with no token and
  no IP on input, so it fills the popup's confirmation line in that state. It stays strictly
  informational: `GeoProbeReport.outcome` still requires ipinfo, so the verdict remains
  `.unavailable` and the guard stays fail-closed. A single unconfirmed source is not allowed
  to decide anything — that is the same rule that makes a missing confirmation a kill reason.

Implementation: `macos/Sources/WetoSystem/GeoProbe.swift`, `macos/Sources/WetoCore/Constants.swift`.
Flow: [overview](../overview.md). Module: [weto-system](../modules/weto-system.md).
