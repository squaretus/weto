# Decision: the user picks a VPN application, not a tunnel

## Context

The guard needs to know whether the machine is behind the user's VPN. For a year that question was
answered by identity: the user picked a tunnel — a network service UUID on macOS, an interface name
on Linux — and the guard checked whether that thing was up and carrying the traffic.

Every part of that turned out to be expensive:

- **The question is unanswerable.** The picker offered `utun1`, `utun6`, `utun8`, `wg0`. Names carry
  no meaning, several housekeeping tunnels are always alive (iCloud Private Relay, AirDrop, a
  corporate client), and the user has no way to tell which one is theirs. A non-technical colleague
  had to guess.
- **The identity is unstable.** A client that reconnects gets a different `utunN`, and the stored
  choice silently became "not connected" — targets then died forever with a reason the user could
  not act on.
- **Half the clients have no identity at all.** Builds distributed outside the App Store open their
  own `utun` in user space: `scutil --nc list` is empty, there is no `Setup:/Network/Service/…`
  entry, and `PrimaryInterface` names the underlying Wi-Fi while every public packet already leaves
  through the tunnel. Verified on a live machine — this is what made the guard announce "VPN is up
  but the traffic goes past it" on a perfectly healthy VPN.
- **It cost two platform implementations** (`SCDynamicStore` service parsing vs `/sys/class/net`
  reading with `DEVTYPE` qualification) with two different failure modes.

## Decision

**The user picks the application that brings the VPN up** — by bundle ID or path, exactly the way
targets are picked. The chosen app being alive is a local ground for the verdict; whether the
traffic is actually tunnelled is answered by geo, and that answer is mandatory.

The tunnel is not identified at all. What survives from the network layer is one question asked of
the kernel — *which interface will carry the verdict request* — and its only job is to tell whether
the previous verdict may still stand.

## Why this is not weaker

- "The app is running" is a weaker claim than "the tunnel is up", and it is not asked to carry more.
  A client can sit in the menu bar with the connection off; the country check catches exactly that.
  Both users' real address is Russian and `RU` is blocked, so the geo half is a hard contour for
  them.
- Closing the client is caught instantly (`didTerminateApplicationNotification`) — better than the
  old path, which noticed only on the next tick.
- Losing the tunnel is caught by the fingerprint: the traffic carrier changes, the verdict is void,
  and targets die before any request.

## Consequences

- The picker, the interface qualification, the "(не подключён)" row and the whole `interface:` id
  scheme are gone: `VPNPicker`, `VPNStatusResolver`, `TunnelInterface`, `NetworkServiceSnapshot` on
  macOS; `vpn_rows`, `vpn_candidates`, `resolve_vpn_status` and the sysfs reader on Linux.
- The stored setting key is new. The old value names a `utunN` or a service UUID, so it cannot be
  migrated — the app has to be chosen once, by hand.
- The chosen app can never be a target, and choosing it removes it from the target list. A guard
  that kills its own source of protection leaves the unsafe state irreversible.
- Known limits, unchanged by this decision and worth stating: per-application split tunnelling is
  not detected (the geo request may go through the tunnel while a target's traffic does not);
  travelling to a country that is not on the block list removes the protection; a VPN with no
  process (`wg-quick`) cannot be chosen.
