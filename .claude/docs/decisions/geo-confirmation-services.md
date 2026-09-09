# Decision: which geo services confirm the country, and why no cache

## Context

The guard needs two independent answers about the same public address: which IP we are
seen as, and which country that IP is in. A wrong or stale country answer is not a cosmetic
bug — it either kills the user's targets on a healthy VPN, or leaves them running while the
traffic is already leaking. Rate limits matter more than usual: every user behind one VPN
exit shares that exit's address, so per-client-IP quotas are effectively per-VPN quotas.

## Decision

- **Three services, no more.** `v4.api.ipinfo.io/lite/me` is the only IP source and the primary
  country source, asked on every probe; the two confirmations are `get.geojs.io` and
  `free.freeipapi.com`. Three is the ceiling because a per-tick rhythm across more of them would
  blow the smaller quotas, and every extra service is another thing to re-measure.
- **A service is only trustworthy while the provider releases it through the chosen profile.**
  Nothing here bypasses the tunnel: *all* traffic goes through it. The provider then picks the
  egress **on its own server, per destination** — some destinations leave through the chosen
  profile (KZ), others are released as RU. A destination released as RU therefore reports an RU
  address on a perfectly healthy tunnel, and the guard reads that as a changed exit. Which
  destinations go which way is the provider's decision and it changes over time, so the check is
  a repeatable procedure, not a one-off:
  [runbooks/verify-geo-services](../runbooks/verify-geo-services.md).
- **The two confirmations are substitutes, not a primary with a fallback.** Whichever answers
  names itself in `confirmSource`. A service that fails or is rate-limited is put on a
  per-service cooldown (`Constants.confirmationCooldownSeconds` / `CONFIRMATION_COOLDOWN`,
  300 s) and the other one is asked instead. A service on cooldown is *not* counted as "the
  services did not answer" — it was not asked, and its trace says so
  (`GeoServiceTrace.coolingDown`). Only when both are unavailable is the confirmation genuinely
  missing, which is `unproven` ⇒ pause. Cooldown is a preference between equals, not a ban:
  when every service is cooling they are all asked anyway, otherwise a single round in which
  both refused would leave the guard without a confirmation for five minutes with nothing able
  to bring it back. The number sits between the cache ceilings on purpose — shorter than the
  soft one (60 s) would skip nothing, longer than the hard one (15 min) would keep a service
  away past the point where the cached answer expires.
- **Address and primary country are never cached; the confirmation is cached per address.**
  Soft ceiling 60 s (refresh attempt, a failure changes nothing), hard ceiling 15 min (the answer
  is no longer good enough). The cooldown changes *which* service is asked, not how often.
- **When ipinfo refuses, the reference endpoint (`get.geojs.io/v1/ip/country.json`) is asked about
  our own address.** Same address as the last verdict ⇒ same country, so the previous verdict
  stands and the shield turns yellow. A different address, or silence from both, pauses.
  There is no third self-IP source: see the egress measurement below.

## Why these, measured rather than assumed

Measured on the owner's machine: the profile exit is `203.0.113.177` (KZ), and destinations the
provider releases as RU report `203.0.113.231`. Both numbers come out of the same tunnel — the
difference is which egress the provider's server chose for that destination. Only the
KZ-released ones are candidates; the RU-released ones describe the provider's other exit, not us.

| Service | Released as | Limit | Verdict |
|---|---|---|---|
| ipinfo Lite (`v4.api.ipinfo.io`) | KZ profile | token required, no daily or monthly cap | IP source and primary country, asked every probe |
| `free.freeipapi.com` | KZ profile | 60 requests/minute, no key | confirmation, interchangeable with geojs |
| `get.geojs.io` | KZ profile | no published cap | confirmation, interchangeable with freeipapi |
| `api.country.is` | KZ profile | 10 requests/second, no quota, free for commercial use | documented spare — swap in by changing one URL constant |
| `ipwho.is` | KZ profile | 1000/day, no key | documented spare; the daily cap is per client IP, i.e. per VPN exit — usable as a stand-in, not as a per-tick source |
| `ip-api.com` | KZ profile | 45/minute | **rejected twice over:** HTTP only on the free tier, and its ToS forbids commercial use. A kill switch must not trust a plaintext geo answer |
| `checkip.amazonaws.com`, `api.ipify.org`, `icanhazip.com`, `ifconfig.me`, `ident.me`, `api.seeip.org`, `1.1.1.1/cdn-cgi/trace`, `api.ipapi.is`, `ifconfig.co` | **RU** | — | rejected: they report the RU exit while the KZ profile is perfectly healthy. `checkip.amazonaws.com` had been the third self-IP source and was removed for exactly this — a healthy profile read as a changed exit, and the targets paused on a lie |
| `ipapi.co`, `api.myip.com`, `api.ip.sb` | — | — | rejected: no answer at all |
| `check-host.net/ip-info` | — | — | rejected: HTML only, no machine-readable answer |
| `ipcheck.ing` | — | — | rejected: 403 to anything that is not a browser |
| `ipquery.io` | — | — | rejected: stale registration data on reassigned ranges |
| `ifconfig.co` | RU | — | rejected on both counts: released as RU *and* stale registration data |

The stale-data ones are the subtle rejections: on reassigned address ranges they report the
country from outdated registration records. Against a correct answer from the other service that
reads as "the services disagree", which is a kill reason — so a bad confirmer does not fail safe,
it fails loud and wrong. The RU-released ones fail the other way and just as loudly: they
describe an exit we are not using.

Note what this does *not* mean: an RU answer here is not a leak and not a bypass. The tunnel is
up and carrying that request; the provider simply released it from a different exit. Telling the
two apart matters, because a real leak deserves a pause and this does not — the honest test is in
the runbook: switch the profile off and see whether the RU address changes.

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
- Swapping or adding a service means re-measuring, not just editing a URL: the provider has to be
  releasing it through the chosen profile *now*, its limit has to hold at our per-probe rate, and
  its data has to be accurate on reassigned ranges. `api.country.is` and `ipwho.is` are already
  measured, so a swap is one constant (`Constants.freeipapiURL` / `Constants.geojsURL`,
  `GeoEndpoints` on Linux) plus a decoder — and a re-run of the runbook, because the provider's
  per-destination choice drifts.
- The cooldown does not protect against a service that answers *wrongly*, only against one that
  refuses. A confirmer with stale registration data still produces a country conflict, which is
  a kill reason; that is why accuracy is a selection criterion and not something the runtime can
  paper over.

- Without an ipinfo token the probe has no IP to ask about, and until this was addressed it
  returned "no token" without touching the network — a fresh install could not answer "where
  am I" at all. `get.geojs.io/v1/ip/country.json` answers about the caller with no token and
  no IP on input, so it fills the popup's confirmation line in that state. It stays strictly
  informational: `GeoProbeReport.outcome` still requires ipinfo, so the verdict remains
  `.unavailable` and the guard stays fail-closed. A single unconfirmed source is not allowed
  to decide anything — that is the same rule that makes a missing confirmation a kill reason.

Implementation: `macos/Sources/WetoSystem/GeoProbe.swift`, `macos/Sources/WetoCore/Constants.swift`,
`linux/crates/weto-sys/src/geo_probe.rs`. Procedure:
[runbooks/verify-geo-services](../runbooks/verify-geo-services.md).
Flow: [overview](../overview.md). Module: [weto-system](../modules/weto-system.md).
