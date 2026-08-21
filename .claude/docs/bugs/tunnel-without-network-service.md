# Bug: "VPN is up but the traffic goes past it" on a healthy tunnel

## Symptom

On a colleague's machine (Happ 3.3.6 from GitHub, VPN exit in Austria) the guard killed the targets
with «VPN поднят, но трафик идёт мимо него» while the VPN was working normally — and the menu bar
showed no country flag. On the owner's machine (Happ from the App Store) the same build behaved
correctly, which is what made the report look like magic.

## What the live machine said

A read-only diagnostic run on her machine, with the VPN connected:

```
Happ 3.3.6 | not App Store | no tunnel extension
scutil --nc list                → empty
State:/Network/Global/IPv4      → PrimaryInterface: en0, PrimaryService: <Wi-Fi>
utun6                           → 172.18.0.1 (alive)
route get default               → en0
route get 8.8.8.8 / ipinfo.io   → utun6
vpnServiceID                    → "interface:utun6"
```

Two independent facts, either of which alone breaks the old logic:

1. **The tunnel has no network service.** `State:/Network/Global/IPv4` is computed by `configd` by
   ranking *network services*; a tunnel opened outside NetworkExtension has none, so
   `PrimaryInterface` can only ever name the underlying Wi-Fi. The branch that was supposed to cover
   this case (`primaryInterface == interface`) therefore fired only when a service already existed —
   exactly where it was not needed. The claim in `weto-system.md` that `PrimaryInterface` names the
   tunnel was wrong; it held on the owner's machine because the App Store build registers a real
   service (`su.ffg.happ`).
2. **The client does not claim the default route at all.** It lays down prefix routes, so any
   "who owns the default route" check answers `en0` even though every public packet leaves through
   `utun6`. A naive port of the Linux formulation would have failed the same way.

The missing flag was not a network failure: `at.svg` was already in her cache and jsdelivr answered
200. `currentCountryCode` returns `nil` for `.unsafe(.vpnNotPrimary)` on purpose, so the flag
disappeared *because* of the wrong verdict.

## Fix

- The traffic carrier is asked of the kernel (`connect` UDP + `getsockname`), never of the network
  configuration, and the probe destination is the ipinfo host — on the owner's machine `1.1.1.1` is
  pinned to `en0` by an explicit route, so a fixed address would have declared a healthy tunnel
  broken.
- Tunnel identity was removed altogether: the user picks the VPN *application*
  (`decisions/vpn-app-instead-of-tunnel.md`).
- `PF_ROUTE` subscription added: this client's route edits touch neither `Global/IPv4` nor any
  service, so the old subscriptions could not see them at all.
- Flags ship in the bundle, so a wrong verdict is the only way the flag can go missing now.

## Second report, same day

Another user: ipinfo requests failed intermittently and the guard killed `claude` each time, on an
unchanged VPN. Arithmetic confirmed it — the tick rate *was* the request rate, 12 probes/minute,
~520 000/month per service, against a freeipapi quota counted per exit address and shared with every
other client on that node. Fixed by splitting the two rates and by proving the address is unchanged
instead of trusting time: see `decisions/geo-confirmation-services.md`.

## How to reproduce the diagnosis

The read-only script used on her machine collects exactly the fields above (system version, VPN
client provenance, `Global/IPv4`, `route -n get` for several destinations, live tunnels, the guard's
own setting, geo-service reachability). Keep it out of the repository — it is a one-off support tool,
not part of the product.
