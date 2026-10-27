# Decision: the terminal version may name the VPN as a tunnel

## Problem
`decisions/vpn-app-instead-of-tunnel.md` removed the tunnel picker and left a known gap: a VPN with
no process (`wg-quick`, a systemd unit running `openvpn`/`wireguard`) cannot be chosen. On a
desktop that gap is rare. On a server — the reason the terminal version (`weto`) exists — it
is the normal case: there is no VPN application at all, so the guard would run on geo alone and
miss the cheapest, fastest signal that the VPN is gone.

## Decision
In the terminal version the VPN can be set as a **tunnel** — an interface name (`wg0`, `tun0`,
`utun6`) via `weto vpn set <name>` (`--tunnel` to force; without a flag an existing interface
name wins over a program of the same name) — **mutually exclusive** with the VPN app: setting one
clears the other in the settings setters (`SettingsStore.vpnTunnel` / `vpnAppRule`,
`Settings::set_vpn_tunnel` / `set_vpn_app`). The GUI on both platforms never offers it; the CLI
keeps its own settings store, so the window cannot even see a tunnel.

The core computes `VPNTunnelStatus` / `VpnTunnelStatus` as a pure function of the chosen name and
the pass's network snapshot:
- not among raised interfaces (`IFF_UP` **and** `IFF_RUNNING`) → `down` → `kill(vpnTunnelDown)`;
- raised, but the kernel route to the ipinfo host leaves through another interface →
  `bypassed(via)` → `kill(trafficBypassesTunnel)`;
- otherwise (the carrier is the tunnel, or there is no carrier) → `carrying` → geo decides.

Both evidences are **local**, like `vpnAppNotRunning` (`UnsafeEvidence.isLocal`): applied at once,
before any network request, and lifted by a reassessment against the still-valid verdict when the
local check stops producing them.

## Reasoning
- **On a server the interface question is answerable**, which is exactly what failed on desktops:
  the admin wrote `wg0` into the config themselves, names are stable across reconnects, and there
  are no housekeeping `utunN` to confuse it with. Nobody is asked "which of `utun1..8` is yours".
- **Why CLI only.** On macOS desktops the original objections still hold (unstable `utunN`,
  user-space tunnels without a service, a non-technical user guessing). Bringing the picker back to
  the window would bring those failures back with it.
- **`bypassed` is judged by the kernel route to the ipinfo host**, the same probe the verdict
  fingerprint uses — not by the default route or interface configuration (`wg-quick` puts its
  default route in table 51820; clients lay down prefix routes). The question is "does the
  verdict request travel through the tunnel", which is what geo then confirms.
- **No carrier is `carrying`, not `bypassed`.** Nothing leaves the machine, so there is no leak;
  the probe fails and the guard pauses — the normal "unproven" path.
- **Local evidence, reassessment without a probe.** A tunnel that comes back while the verdict
  still matches the fingerprint must release targets as fast as a VPN app that comes back;
  waiting for a probe would keep targets dead for nothing.
- **Raised interfaces stay out of the fingerprint.** Only the tunnel status reads the list; a
  second VPN reconnecting next to the working one must not void the verdict.

## Consequences
- `NetworkSnapshot` gained `upInterfaces` / `up_interfaces` (serde default empty) and a new system
  boundary, `InterfaceListing` (`KernelInterfaceList` on macOS, `KernelInterfaces` on Linux).
- Policy order: app check (if an app is chosen), then tunnel check (if a tunnel is chosen), then the
  network verdict. Pinned by `guard-policy.json` v5 and two cases in `guard-transitions.json`.
- A tunnel name that is not up when set is accepted with a warning — `wg0` may legitimately be down
  at that moment — and from then on targets die until it is up. That is the intended fail-closed
  behaviour, and the CLI says so.
- A tunnel that carries the verdict request but not a target's traffic (split routing by
  destination) is still "carrying"; per-destination leaks remain geo's job, as before.
