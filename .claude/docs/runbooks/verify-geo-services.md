# Verify which geo services the provider releases through the chosen profile

Every geo service weto asks must come back with **the chosen profile's exit**. Nothing here
bypasses the tunnel — all traffic goes through it. The provider picks the egress **on its own
server, per destination**: some destinations leave through the chosen profile (KZ), others it
releases as RU. A destination released as RU answers about that other exit, so on a perfectly
healthy profile it reports the wrong address and the guard reads that as a changed exit — a pause,
or a country conflict, on a lie.

Which destinations go which way is the provider's decision, and it changes whenever they like.
Treat this as a recurring check, not a one-time selection: run it when a geo answer looks wrong,
when the popup shows an address you do not recognise, before swapping any service constant, and
after the VPN client updates.

No Docker, no build — plain `curl` on the host with the profile **connected**.

## Steps

### 1. Establish the two exits

Get the profile exit from a service already known to be released through the profile, and the
provider's RU exit from one known to be released as RU. Both numbers are the yardstick for
everything below.

```bash
curl -s https://get.geojs.io/v1/ip/country.json              # profile exit + country
curl -s https://checkip.amazonaws.com                        # RU exit (provider), for contrast
```

Last measurement on the owner's machine: profile `91.224.74.177` (KZ), RU-released
`185.228.113.231`. Write down your own pair before continuing — the rest of the procedure is a
comparison against them.

If both answers are the same address, either the provider is releasing everything through one
exit or the tunnel is down. Stop and settle that first (step 3): nothing measured in this state
means anything.

### 2. Ask every candidate and compare

```bash
for url in \
  https://v4.api.ipinfo.io/lite/me \
  https://get.geojs.io/v1/ip/country.json \
  https://free.freeipapi.com/api/json/ \
  https://ipwho.is/ \
  https://api.country.is/ \
  https://api.ipify.org \
  https://icanhazip.com \
  https://ifconfig.me \
  https://ident.me \
  https://api.seeip.org \
  https://1.1.1.1/cdn-cgi/trace \
  https://api.ipapi.is \
  https://ifconfig.co/json
do
  printf '%-45s %s\n' "$url" "$(curl -s --max-time 5 "$url" | tr -d '\n' | cut -c1-120)"
done
```

`v4.api.ipinfo.io/lite/me` needs the token: add `-H "Authorization: Bearer $TOKEN"` (the token
lives in the Keychain under `com.weto.ipinfo`; never paste it into a URL or a file).

Read the result by address, not by hope:

- address == profile exit ⇒ **released through the profile**, the service is a candidate.
- address == RU exit ⇒ **released as RU**, the service is disqualified. No amount of accuracy or
  generosity in its limits changes this.
- no answer, HTML, or `403` ⇒ unusable. Record it so the next person does not retry it.

Then check the two things that measurement cannot see: the published limit and the terms. A free
tier that is **HTTP only** is rejected outright — a kill switch must not trust a plaintext geo
answer — and so is one whose ToS forbids commercial use. That is what disqualified `ip-api.com`
despite the provider releasing it through the profile with a workable 45/minute.

### 3. Tell a provider RU-egress apart from a real bypass

An RU answer has two possible causes, and they deserve opposite reactions: the provider released
that destination from its RU exit (normal, the tunnel is fine), or the traffic never entered the
tunnel at all (a real leak, and the guard is right to pause). The honest way to tell them apart
is to take the provider out of the picture:

```bash
curl -s https://checkip.amazonaws.com     # profile connected
# disconnect the VPN profile in the client, then:
curl -s https://checkip.amazonaws.com     # profile off
```

- the address **changes** when the profile goes off ⇒ the request *was* going through the
  provider, which released it as RU. Provider-side egress selection, not a bypass.
- the address is the **same** either way ⇒ that destination is genuinely leaving outside the
  tunnel. This is a leak; the service is not the problem and the client is.

Reconnect the profile before measuring anything else.

### 4. Cross-check the route (secondary, not decisive)

```bash
route -n get 91.224.74.177          # or the candidate's resolved address
scutil --nc list                    # which tunnels exist at all
```

`route -n get` says which interface the kernel *intends* to use. Useful for spotting a host the
client has pinned to `en0` with its own prefix route — but **it is not the verdict**. `utun*` in
the answer tells you nothing about which egress the provider used: the flow enters the tunnel and
the choice is made on the provider's server, past anything the local route table can show. The
observed address from step 2 is what decides; `route` only explains the local half.

### 5. Write the result down

The selection is canon and lives in two places, both of which have to agree with what you just
measured:

- `.claude/docs/decisions/geo-confirmation-services.md` — the table: which exit each service is
  released through, limit, verdict, and the reason for every rejection.
- `.claude/rules/ARCHITECTURE.md` — the geo bullet: three services, which two are the
  interchangeable confirmations.

If a service changed sides, swapping it is one URL constant plus a decoder:
`Constants.freeipapiURL` / `Constants.geojsURL` in `macos/Sources/WetoCore/Constants.swift`,
`GeoEndpoints` in `linux/crates/weto-sys/src/geo_probe.rs`, and `GeoResponses` /
`weto_core::geo::responses` for the shape of the answer. Both platforms move together, and the
tests in `macos/Tests/WetoSystemTests/GeoProbeTests.swift` and
`linux/crates/weto-sys/tests/geo_probe.rs` are where the new behaviour gets pinned.

Already-measured spares, so a swap does not start from scratch: `api.country.is` (10
requests/second, no quota, free for commercial use) and `ipwho.is` (1000/day, no key — per client
IP, so per VPN exit).

## Notes

- Most IP checkers are released as RU by this provider, Russian services among them. That is a
  property of the provider's per-destination egress selection, not of the services.
- The guard asks at most three services on purpose: a per-tick rhythm across more of them would
  blow the smaller quotas. Two of the three are interchangeable confirmations, and a refusal puts
  that service on a 300 s cooldown while the other answers — so a single flaky confirmer is not
  an outage.
- A confirmation quota is counted per client address, which behind a VPN means per exit node:
  the quota is shared with every other client on that node. Measure the limit against our real
  spend (about one request per minute), not against the tick rate.
