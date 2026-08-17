# Linux guard (Rust)

The Linux implementation of weto's guard: same product, same policy, no shared code with
the Swift side — only shared data (`shared/fixtures`, `shared/icon`, `shared/tokens`).

## Key files

| Crate | File | Responsibility |
|---|---|---|
| `weto-core` | `policy.rs` | `decide`, `decide_local`, `pending_verification` — port of `GuardPolicy` |
| `weto-core` | `network.rs` | `NetworkSnapshot`, `verdict_fingerprint`, `resolve_vpn_status` |
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

## The UI is a port, not a redesign

Both windows mirror their macOS counterparts element for element, and the list below is
the whole of what the Linux side is allowed to differ in:

| macOS | Linux | Why |
|---|---|---|
| popup anchored to the menu bar icon | ordinary window | SNI reports no coordinates; Wayland forbids self-positioning |
| target hint mentions bundles | hint mentions command and path only | `appBundle` does not exist here |
| `NSAlert` for destructive confirmations | `Gtk.AlertDialog` | each platform asks its own dialog |
| — | tray context menu (check / settings / quit) | SNI needs one; the popup carries the same actions |

Everything else matches: the settings window is the same five cards in the same order
(`Цели`, `Сеть и гео`, `Чёрный список`, `Внешний вид`, `Обслуживание`) plus the same
footer (github link, version, update tile), and the status popup is shield + title +
two icon buttons, then the geo readout, the update banner, and live targets.

**There is no guard on/off switch, and that is deliberate.** `is_enabled` exists in the
settings model on both platforms and is exposed by neither. The same goes for a
"notify on kill" switch: macOS has no such setting, so notifications always fire.

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
- **CSS variables are not used:** `var()` arrived in GTK 4.16 and the project floor is 4.14
  (Ubuntu 24.04 LTS), where such rules are silently dropped. Values are substituted by the
  generator instead — one stylesheet per theme, and `css.rs` fails if a `var(--` survives.
- **The stock theme paints buttons with a gradient.** Breeze and Adwaita put a
  `background-image` on top of our `background-color`, so without an explicit
  `background-image: none` the button stays light and light text on it disappears. The reset
  is mandatory on every control we fill; `css.rs` fails the build if one is missing.
- **The geo readout refreshes on every network change**, not only when the verdict needs the
  network — same contract as `WetoShared`. One probe per (revision + fingerprint) pair, only
  while the guard is armed, and the stale report is dropped first. The fingerprint is
  `verdict_fingerprint(settings.vpn_interface)` — the chosen interface and the default-route
  owner, never the whole interface list: a second tunnel appearing or vanishing beside the
  chosen one must not cost the user their targets.
- **The chosen tunnel survives going offline.** `vpn_rows` keeps the stored choice as a
  "(не подключён)" row and separates rebuilding the list from a user's click; without that
  separation switching the VPN off silently erased the setting, and the guard then reported
  "VPN not selected" instead of "VPN down".

## Self-update

Checked at start-up and hourly, installed by the same process into the home directory.
The decision comes from the same pure function as on macOS and is checked by the shared
fixtures. A silent outcome hides both the window and the banner; auto-install runs without
a dialog; the restart is an `exec` over itself, by which point the launch symlink already
points at the new version.

- **Rollback is built in:** a start attempt is marked before any window is created and
  cleared after five seconds of life. Two failures in a row mean the version does not
  start, and the app returns to the previous one by itself. macOS needs no such safety net —
  there the system installer validates the package.
- **A manual check ignores skip and deferral** — the only and sufficient way to bring back
  a skipped version, which is why there is no "unskip" button.
- **No root anywhere:** not for installing, updating, killing targets or reading routes.
  There is no privileged helper in the Linux build at all. Download protection is the same
  as on macOS — https plus the GitHub delivery host list; neither platform has a signature,
  and splitting them over that would be a decision without a reason.

## Divergence control

`shared/fixtures/guard-policy.json` holds 27 cases extracted from the existing Swift
tests. Both `weto-core/tests/policy_fixtures.rs` and
`macos/Tests/WetoCoreTests/GuardPolicyFixtureTests.swift` run them. A behavioural drift
between platforms fails a test naming the case, instead of surfacing as a kill-switch
that quietly stopped working on one OS.

## Testing

179 tests, run in a Linux container (`linux/scripts/dev.sh`). Two contracts need
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
