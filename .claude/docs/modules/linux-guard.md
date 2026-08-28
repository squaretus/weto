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
| `weto-sys` | `network_snapshot.rs` | kernel route probe: who carries the traffic |
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
| country flag in the menu bar | country name as text | no flag rendering here yet; the set ships with macOS only |
| app picker via `NSOpenPanel` | command or path typed into a field | no equivalent panel; targets are added the same way |

Everything else matches: the settings window is the same six cards in the same order
(`Цели`, `Сеть и гео`, `Чёрный список`, `Белый список`, `Внешний вид`, `Обслуживание`) plus the same
footer (github link, version, update tile), and the status popup is shield + title +
two icon buttons, then the geo readout, the update banner, and live targets.

**There is no guard on/off switch, and that is deliberate.** `is_enabled` exists in the
settings model on both platforms and is exposed by neither. The same goes for a
"notify on kill" switch: macOS has no such setting, so notifications always fire.

## Contracts that differ from macOS

Everything the policy decides is shared. What the system dictates is not:

- **The VPN is a chosen application, same as on macOS.** Interface names (`wg0`, `tun0`) meant
  nothing to the user and changed between runs; sysfs reading and the tunnel qualification
  (`DEVTYPE`, `tun_flags`, ARPHRD) went away with the picker. What survived is the route probe —
  it answers whether traffic flows, which is the only thing the verdict needs.
- **A VPN without a process cannot be chosen.** `wg-quick` brings an interface up and exits;
  there is nothing to watch. Such a setup leaves the choice empty, which is fail-closed, and the
  geo half of the policy still works once an app is picked. macOS has no equivalent gap because
  every client there is an app.
- **Network events come from a netlink subscription**, the replacement for
  `NWPathMonitor`: single-digit milliseconds instead of waiting out a five-second tick.
  Locked down by `netlink-events-contract.sh`.
- **The poll stays** (1 s while safe, 250 ms while unsafe). Catching launches through the netlink
  connector needs `CAP_NET_ADMIN`, and the whole installation is designed to be unprivileged.
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
- **`min-height` in GTK is the content box, and the border adds to it.** Every pill, the
  entry and the dropdown therefore declare `min-height: calc({{controlHeight}} - 2px)` plus
  a 1px border — transparent on the primary and destructive kinds, coloured on the muted one.
  Without that transparent border the primary button was 2px shorter than the muted one
  standing next to it, and the update window's action row visibly tilted. `controls.rs`
  measures live widgets rather than reading the CSS: the height is a sum of three
  declarations and an error in any of them only shows in the total.
- **A row of buttons is `homogeneous`, not three `hexpand` children.** `hexpand` splits only
  the leftover space, and the natural width of the labels differs, so the buttons came out
  different sizes. `ui::action_row()` owns both that and the vertical centring; a GTK button
  fills the row height by default and needs `valign: Center` to stay a pill.
- **The geo readout refreshes on every network change**, not only when the verdict needs the
  network — same contract as `WetoShared`. The geo schedule (5 s) and a fingerprint change are what
  send a request; the stale report is dropped first. The fingerprint is `verdict_fingerprint()` —
  the traffic carrier and its local address, never the interface list: a second tunnel appearing or
  vanishing beside the working one must not cost the user their targets.
- **The confirmation cache and the reference-address fallback are identical to macOS**, down to the
  60 s / 15 min ceilings: the freeipapi quota counts per exit address and is shared with everyone
  else on that node, so its 429 must not kill targets.
- **Both geo lists share one builder and one storage path.** `geo_list_card(state, kind, title)` is
  called twice, and `Settings::entries/add_entry/remove_entry` take a `GeoListKind`; the
  `…_blocked_entry` / `…_allowed_entry` functions only delegate. Same shape as macOS, and for the
  same reason — a second copy of the parse-and-dedupe algorithm would drift silently.
  `allowed_countries` / `allowed_ip_ranges` are `serde(default)`, so a config written before the
  whitelist existed loads as an empty one.
- **The journal keeps one record per killed process and one `episode_id` per pass**, same
  contract as `WetoShared`. `KillReporting` carries a `KillContext` — reason, geo readout,
  diagnostics — instead of a bare `&str`: `report` fires only when something was actually killed,
  and by the time the verdict is known the targets are already dead, so `refine` and
  `resolved_safe` exist as separate calls. Without them the records keep saying "not verified yet"
  forever. `Journal::refine_episode` rewrites every record of the episode.
- The episode ledger lives in `weto_core::episode::EpisodeLedger`, not in the app layer:
  the rule is identical on both platforms, and the app crate has no tests — a mistake in it
  showed up only on a live machine, as "launch blocked" records for a process killed for the
  first time. `episode_finished` fires on **every** transition to safe, not just for an episode
  that began before the verdict: that call is where the ledger is reset.
- Dedup is by the pair **reason + pid**. It used to be by reason alone, which never let a target
  launched mid-episode into the journal at all: the user saw a kill the journal did not remember,
  and no notification either.
- Records carry ip and countries now. They used to be `None` always — not a storage gap but a
  wiring one: the reporter was never handed the readout.
- **One journal, not two.** `AppState` and `JournalWriter` each held their own `Mutex<Journal>`
  loaded from the same file and never synced: new kills never appeared in the settings window, and
  "clear journal" wiped only the displayed copy, after which the next write restored everything.
  Both now share one `Arc<Mutex<Journal>>`.
- **Timestamps serialise as ISO 8601 strings** (`weto_core::timestamp`). `SystemTime` defaults to
  a `{secs_since_epoch, nanos}` object, and macOS writes strings; the export is read by a human or
  an agent, so one format is mandatory. Field names with acronyms (`episodeID`, `parentPID`,
  `allowedIPRanges`, `hasIPInfoToken`) are renamed explicitly — serde's camelCase would give
  `episodeId`, and the file would need two parsers.

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

`shared/fixtures/guard-policy.json` (`version: 3`) holds 36 cases extracted from the existing
Swift tests. `allowedCountries` / `allowedIPRanges` are optional in both runners, so a case that
predates the whitelist keeps its exact previous meaning. Both `weto-core/tests/policy_fixtures.rs` and
`macos/Tests/WetoCoreTests/GuardPolicyFixtureTests.swift` run them. A behavioural drift
between platforms fails a test naming the case, instead of surfacing as a kill-switch
that quietly stopped working on one OS.

## Testing

196 tests, run in a Linux container (`linux/scripts/dev.sh`). Two contracts need
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
