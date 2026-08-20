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
- **Address and primary country are never cached; the confirmation is cached per address.**
  Soft ceiling 60 s (refresh attempt, a failure changes nothing), hard ceiling 15 min (the answer
  is no longer good enough).
- **When ipinfo refuses, the reference endpoint (`get.geojs.io/v1/ip/country.json`) is asked about
  our own address.** Same address as the last verdict ⇒ same country, so the previous verdict
  stands and the shield turns yellow. A different address, or silence from both, kills.

## Why these, measured rather than assumed

| Service | Limit | Verdict |
|---|---|---|
| ipinfo Lite | none declared | IP source, asked every 5 s |
| `free.freeipapi.com` | 60 requests/minute — our spend is ~1 | primary confirmation |
| `get.geojs.io` | no declared limit | fallback |
| `ipwho.is` | 1000/day **per client IP** | rejected: burned out in ~1.4 h behind one VPN exit |
| `ipquery.io` | — | rejected: stale registration data on reassigned ranges |
| `ifconfig.co` | — | rejected: same, gives a false country mismatch |

The last two are the subtle ones: on reassigned address ranges they report the country from
outdated registration records. Against a correct answer from the other service that reads as
"the services disagree", which is a kill reason — so a bad confirmer does not fail safe, it
fails loud and wrong.

## Why the spend was cut, and where exactly

The tick rate and the request rate used to be the same number. At a 5 s tick that is 12 probes per
minute — about 520 000 per month against *each* service. The freeipapi limit is counted per client
IP, which behind a VPN means per exit node: we were taking 12 of the 60 per minute and sharing the
rest with every other client on that node. Its 429s arrived regularly, and strict fail-closed turned
each one into a dead `claude` on a perfectly healthy VPN.

What changed:

- ipinfo keeps the 5 s cadence — it is the detector of a country change, and it has no declared limit.
- The confirmation answers "which country is *this address* in". For an unchanged address that answer
  does not change every five seconds, so it is cached by address: one request per minute instead of
  twelve, ~1.7% of the shared per-node quota instead of 20%.
- A failed refresh inside the hard ceiling changes nothing. That decouples "the third party is
  flaky" from "the targets must die", which was the whole complaint.

## Consequences

- Caching the *address* or the primary country is still refused at every level: ephemeral session
  config, `urlCache = nil`, and `reloadIgnoringLocalAndRemoteCacheData` on both the configuration
  and each request. A country change on an unchanged address is caught by ipinfo within 5 s; the
  ceilings only govern the second opinion.
- The ipinfo host doubles as the route probe's destination: the guard must know which interface the
  verdict request itself will travel through, and fixed public addresses get excluded from tunnels
  by clients.
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
