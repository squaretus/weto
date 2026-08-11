# Linux guard (Rust)

The Linux implementation of weto's guard: same product, same policy, no shared code with
the Swift side — only shared data (`shared/fixtures`, `shared/icon`, `shared/tokens`).

## Key files

| Crate | File | Responsibility |
|---|---|---|
| `weto-core` | `policy.rs` | `decide`, `decide_local`, `pending_verification` — port of `GuardPolicy` |
| `weto-core` | `network.rs` | `NetworkSnapshot`, `fingerprint`, `resolve_vpn_status` |
| `weto-core` | `process.rs` | target matching, descendant walk — port of `ProcessMatcher`/`ProcessTree` |
| `weto-core` | `geo.rs` | readings, failures, `GeoProbeReport`, response parsing |
| `weto-core` | `ip.rs` | address validation and CIDR |
| `weto-core` | `presentation.rs` | status wording, `ShieldState` |
| `weto-sys` | `network_snapshot.rs` | sysfs interfaces + kernel route probe |
| `weto-sys` | `network_events.rs` | netlink subscription |
| `weto-sys` | `process_registry.rs` | `/proc` reader with a swappable root |
| `weto-sys` | `process_killer.rs` | `SIGTERM` |
| `weto-sys` | `geo_probe.rs` | blocking HTTP probe over ureq |
| `weto-sys` | `secret_store.rs` | token file, mode `0600` |
| `weto-config` | `settings.rs`, `journal.rs`, `paths.rs` | TOML settings, ring-buffer journal, XDG paths |
| `weto-guard` | `controller.rs`, `enforcer.rs` | state machine, one `/proc` pass per tick |
| `wetod` | `main.rs` | test harness: `--dump-network`, `--check`, `--watch` |

## Boundary invariant

`weto-core` may depend only on `serde`, `serde_json` and `thiserror`.
`scripts/tests/core-boundary-contract.sh` fails the build if tokio, zbus, reqwest,
netlink, procfs, gtk4 or rustix ever appear in its dependency graph. Same invariant as
`WetoCore` on macOS, and for the same reason: it keeps the bulk of the tests synchronous
and mock-free.

## Why the route is probed, not read

`wg-quick` installs the default route into table 51820 behind an `ip rule`, leaving the
old Ethernet default in the main table. Reading `/proc/net/route` therefore reports the
wrong interface and the guard would kill targets while the VPN is perfectly healthy.
`KernelRouteProbe` instead opens a UDP socket, `connect`s to a public address (no packet
is sent) and reads back the local address the kernel picked, then maps it to an interface.
Verified against `ip route get` in `policy-routing-contract.sh`.

## Contracts that differ from macOS

Everything the policy decides is shared. What the system dictates is not:

- **VPN is identified by interface name; the tunnel qualification comes from the kernel**
  (`DEVTYPE`, `tun_flags`, ARPHRD), never from the name — a user will call anything "VPN".
  An unknown name resolves to `Down`, fail-closed, same as an unknown UUID on macOS.
- **`is_up` is the IFF_UP bit alone.** IFF_RUNNING is not exposed through sysfs (a working
  `eth0` reads `0x1003`) and "carries link" is undefined for tunnels anyway. Whether
  traffic actually flows through an interface is answered by the route probe.
- **Network events come from a netlink subscription**, the replacement for
  `NWPathMonitor`: single-digit milliseconds instead of waiting out a five-second tick.
  Locked down by `netlink-events-contract.sh`.
- **The 250 ms poll stays.** Catching launches through the netlink connector needs
  `CAP_NET_ADMIN`, and the whole installation is designed to be unprivileged.
- **Two macOS traps are solved by the kernel:** `readlink /proc/<pid>/exe` returns an
  already-resolved path, so the `nano`→`pico` symlink never appears; argv arrives as a
  ready-made array in `cmdline`, so no `KERN_PROCARGS2` parsing is needed.
- **`appBundle` targets do not exist here.** A `.desktop` entry points at an ordinary
  binary, so it is a `Binary` target.

## Divergence control

`shared/fixtures/guard-policy.json` holds 27 cases extracted from the existing Swift
tests. Both `weto-core/tests/policy_fixtures.rs` and
`macos/Tests/WetoCoreTests/GuardPolicyFixtureTests.swift` run them. A behavioural drift
between platforms fails a test naming the case, instead of surfacing as a kill-switch
that quietly stopped working on one OS.

## Testing

156 tests, run in a Linux container (`linux/scripts/dev.sh`). Two contracts need
`CAP_NET_ADMIN` because they create interfaces and routing rules:
`policy-routing-contract.sh` and `netlink-events-contract.sh`. Everything that cannot be
faked — a real WireGuard tunnel, the look of the tray icon — is covered by the
checklists in `linux/docs/manual-check.md` and `linux/docs/manual-ui-check.md`.

## Sibling crates

| Crate | Responsibility |
|---|---|
| `weto-ui` | design system on plain GTK4; two generated stylesheets, one per theme |
| `weto-tray` | StatusNotifierItem icon rendered from the shared `.icon` bundle |
| `weto-update` | release check, show policy, install into `$HOME`, rollback |
| `weto-app` | `weto` binary: status window, settings, update banner and window |

## Not here yet

Secret Service over D-Bus — the token lives in a `0600` file. Country flags and
per-target icons are not fetched, so the status window shows generic glyphs.
