# Linux guard (Rust)

The Linux implementation of weto's guard: same product, same policy, no shared code with
the Swift side — only shared data (`shared/fixtures`, `shared/icon`, `shared/tokens`).

## Key files

| Crate | File | Responsibility |
|---|---|---|
| `weto-core` | `policy.rs` | `decide`, `decide_local` — port of `GuardPolicy`, three-outcome `GuardDecision` |
| `weto-core` | `network.rs` | `NetworkSnapshot`, `verdict_fingerprint`, `resolve_vpn_status` |
| `weto-core` | `process.rs` | target matching, descendant walk — port of `ProcessMatcher`/`ProcessTree` |
| `weto-core` | `geo.rs` | readings, failures, `GeoProbeReport`, response parsing |
| `weto-core` | `ip.rs` | address validation and CIDR |
| `weto-core` | `guard_machine.rs` | `GuardMachine` — the pure reducer: six phases, `GuardEffect`, the 60 s ceiling |
| `weto-core` | `pause_plan.rs` | who gets `SIGSTOP` and in what order; `PausedProcess`, `RecoveredProcess` |
| `weto-core` | `presentation.rs` | status wording built straight from `GuardPhase`: `shield_color`, `explanation`/`should_explain`, `status_lines`, `idle_targets` |
| `weto-sys` | `network_snapshot.rs` | kernel route probe: who carries the traffic |
| `weto-sys` | `network_events.rs` | netlink subscription |
| `weto-sys` | `process_registry.rs` | `/proc` reader with a swappable root; process group, tty foreground group, `T` state |
| `weto-sys` | `process_signaler.rs` | `SIGSTOP` / `SIGCONT` / `SIGKILL`, strictly in list order |
| `weto-sys` | `geo_probe.rs` | blocking HTTP probe over ureq |
| `weto-sys` | `background.rs` | the background track: one thread per probe, so a pass never waits for a request |
| `weto-core` | `terminal.rs` | which ancestor is the terminal; bus name and object path from a desktop id |
| `weto-core` | `launcher.rs` | `.desktop` text: `DesktopCommand`, `name_from_desktop_entry`, wrapper stripping |
| `weto-sys` | `target_resolver.rs` | the same chain on disk: `Resolution`, `display_name_for` |
| `weto-sys` | `desktop_entries.rs` | the `.desktop` index over the XDG application directories |
| `weto-sys` | `terminal.rs` | raises it: `org.freedesktop.Application.Activate` over the session bus |
| `weto-sys` | `session_bus.rs` | one session-bus connection for the whole process, 3 s method ceiling |
| `weto-sys` | `notifications.rs` | notifications over D-Bus; the `default` action opens the status window |
| `weto-sys` | `secret_store.rs` | token file, mode `0600` |
| `weto-config` | `settings.rs`, `journal.rs`, `paths.rs` | TOML settings, ring-buffer journal, XDG paths |
| `weto-config` | `stopped.rs` | the stopped ledger: the obligation to send `SIGCONT`, atomic on disk |
| `weto-guard` | `controller.rs` | owns the reducer, the probe, verdict freshness and the pause bookkeeping |
| `weto-guard` | `enforcer.rs` | one `/proc` walk per pass: pause, resume, terminate, the ledger |
| `weto-app` | `lifecycle.rs` | whether the process outlives its windows (`holds_application`) |
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
| the "Показать терминал" button raises any terminal | the button is there only for an emulator that comes out on the session bus | raising a window means asking the application itself (`org.freedesktop.Application.Activate`); an emulator that owns no bus name — xterm, alacritty, kitty, foot, xfce4-terminal, mate-terminal, terminator — cannot be asked, and nothing short of `wmctrl`/`xdotool` would change that. The `(i)` hint stays: it is the answer the user needs. See "Raising the terminal" below |
| tapping the notification always opens the popup | tapping opens the status window when the notification server announces `actions` | the capability is the server's, not ours (`GetCapabilities`); without it the notification is still delivered, just not clickable |
| — | a second dialog asks for the program file when the picked entry launches through Steam or flatpak | a `.app` always *is* the program; a `.desktop` entry need not name one at all, and guessing would guard the launcher — see the `appBundle` row under "Contracts that differ from macOS" |

Everything else matches, including every wording that does not depend on the unported screen: the
settings window is the same six cards in the same order
(`Цели`, `Сеть и гео`, `Чёрный список`, `Белый список`, `Внешний вид`, `Обслуживание`) plus the same
footer (github link, version, update tile), and the status popup is shield + title +
two icon buttons, then the geo readout, the update banner, and live targets.

**There is no guard on/off switch, and that is deliberate.** `is_enabled` exists in the
settings model on both platforms and is exposed by neither. The same goes for a
"notify on kill" switch: macOS has no such setting, so notifications always fire.

## Raising the terminal

A target that lost its foreground job under pause gets the `fg` hint and, next to it, the
"Показать терминал" button — the same affordance as macOS. What differs is the mechanism:
macOS activates an `NSRunningApplication`, here the application is asked over the session bus.

Two facts are collected about every ancestor of the standing target, and neither is enough
alone:

- the `.desktop` entry (`weto-sys/desktop_entries.rs`, XDG order: `$XDG_DATA_HOME`, then
  `$XDG_DATA_DIRS`) says **who this ancestor is** — every emulator declares
  `Categories=…TerminalEmulator…`, and that is what tells the terminal apart from the rest
  of the ancestry;
- the session bus says **whether it can be raised**: the well-known names owned by that pid
  (`ListNames` + `GetConnectionUnixProcessID`), kept only when the object behind the name
  really exports `org.freedesktop.Application` (`Introspect`).

`weto_core::terminal::choose` then picks, nearest ancestor first: a declared terminal that can
be raised, else any ancestor that can be raised, else a declared terminal that cannot. Nearest,
not topmost — the macOS rule ("topmost process owning a bundle") does not translate, because
above the terminal there is always `systemd --user`, which owns a bus name of its own.

Rule two exists for GNOME Terminal, the default on Ubuntu: its entry declares
`Exec=gnome-terminal` while the shell actually sits under `/usr/libexec/gnome-terminal-server`,
so it is not in the index by executable at all — but it owns `org.gnome.Terminal` and exports
the application interface like every GApplication. `DBusActivatable=true` is deliberately *not*
the test: that flag is about the bus being allowed to **start** the app, and gnome-terminal does
not set it, while the running server answers `Activate` perfectly well.

What the mechanism covers, from the desktop files as shipped by Debian trixie: GNOME Terminal
(`org.gnome.Terminal`, owned by the server), GNOME Console (`org.gnome.Console.desktop`,
`DBusActivatable=true`), Tilix (`com.gexperts.Tilix.desktop`, `DBusActivatable=true`) and, by the
same rule, KDE's Konsole, which registers `org.kde.konsole-<pid>` (the `-<pid>` tail is stripped
when the object path is derived — the KDE convention). What it cannot cover: xterm, alacritty,
kitty, foot, xfce4-terminal, mate-terminal, terminator — they never appear on the session bus,
so there is no one to ask. Those targets keep the hint and lose the button, which is the honest
outcome: a button that does nothing is worse than no button.

The answer is cached per pid by the popup: it costs a `/proc` pass plus one `ListNames` and a
`GetConnectionUnixProcessID` per name, and the popup refreshes twice a second. Every bus call
is capped at 3 s (`session_bus::METHOD_TIMEOUT`) instead of zbus's 25 s default — the lookup runs
on the GTK main loop — and `Activate` itself is sent from a detached thread, so a hung emulator
cannot freeze the window.

Notifications moved to the same bus for the same reason: `notify-send` cannot report a click,
and clicking is what opens the popup on macOS. weto sends `Notify` with the `default` action when
the server announces `actions`, remembers the ids of its own notifications and opens the status
window on `ActionInvoked`. No session bus at all means no notifications — same contract as before,
when the missing tool meant the same thing.

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
  binary, so it is a `Binary` target — but getting from the entry to that binary is a chain, not
  a field. `weto_core::launcher::command_from_desktop_entry` walks the `Exec` line and answers
  with a `DesktopCommand`: wrappers are dropped (a leading `env` with its assignments, one level
  of `sh -c "…"` — taking the first word would have guarded `/usr/bin/env` or `/bin/sh`, i.e. half
  the machine), and `steam` / `flatpak` come back as `Indirect { launcher }` because they start the
  program themselves and the entry does not say what the process will be. Guessing there would
  have made `/usr/bin/steam` the target, so a VPN drop closed every game at once.
  `target_resolver::resolve_launch_entry` carries that verdict to disk as a `Resolution`:
  `NeedsPath { launcher }` is the honest answer, and the settings window asks the user for the
  program file with a second dialog (`ask_for_program_path`). `resolve_launch_target` stays as the
  string façade for callers that only want a path — a foreign launcher looks the same there as a
  target that is not installed: the entry is kept as typed.
- **A target's name comes from the entry's `Name=`, not from the last path segment.**
  `name_from_desktop_entry` prefers `Name[<locale>]` (locale being the first two letters of
  `LC_MESSAGES`/`LANG` — `ru_RU.UTF-8` matches no key as-is) and reads the `[Desktop Entry]`
  section only, so a `[Desktop Action …]` cannot sign the target «Новое окно». Tools living in a
  versioned directory made the old rule produce «2.1.241» instead of «Claude», and the journal then
  could not say what had been closed. The name the user picked survives the second dialog too: when
  the file comes from `ask_for_program_path`, `add_target_named` keeps the entry's name.
- **The app outlives its windows when, and only when, the tray icon came up.** GApplication quits
  once the last window closes, so the window's close button silently dropped the guard: the icon
  disappeared, the targets were left unwatched and the user had merely closed a window. `main.rs`
  therefore takes `app.hold()` when `tray::install` reports success (`lifecycle::holds_application`),
  and the hold guard is kept in a thread-local — dropped on the spot it would hold nothing. Without
  a tray (vanilla GNOME) the old behaviour stays, because a held windowless app could only be closed
  with `kill`. The exit funnel is untouched: `app.quit()` from the tray item and from «Закрыть
  приложение» still goes through `connect_shutdown`. The cost of holding is that per-window timers
  now have to end with their window — `status_window.rs` breaks its 500 ms refresh on
  `connect_destroy`, or every reopen would leave another one running.
- **The settings window holds its own width.** A tiling compositor hands the window the whole cell
  and ignores `default_width`, so card rows (label, `spacer()` with `hexpand`, control) spread to
  its edges. `ui::content_column` wraps the panel at `WINDOW_WIDTH`, centred, with an explicit
  `hexpand(false)` — GTK4 derives a container's expand flag from its children, and one `spacer()`
  deep inside would stretch the column again. The window itself only keeps a floor
  (`MIN_WINDOW_HEIGHT`, 480), below which the segments and the first card start to clip.
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
- **The confirmation cache, the cooldown and the reference-address fallback are identical to
  macOS**, down to the 60 s / 15 min ceilings and the 300 s `CONFIRMATION_COOLDOWN`: the freeipapi
  quota counts per exit address and is shared with everyone else on that node, so its 429 must
  neither kill targets nor be spent again right away. The two confirmers are substitutes here too,
  and `GeoServiceTrace::COOLING_DOWN` is the same text as on macOS.
- **Both geo lists share one builder and one storage path.** `geo_list_card(state, kind, title)` is
  called twice, and `Settings::entries/add_entry/remove_entry` take a `GeoListKind`; the
  `…_blocked_entry` / `…_allowed_entry` functions only delegate. Same shape as macOS, and for the
  same reason — a second copy of the parse-and-dedupe algorithm would drift silently.
  `allowed_countries` / `allowed_ip_ranges` are `serde(default)`, so a config written before the
  whitelist existed loads as an empty one.
- **The journal keeps one record per killed process and one `episode_id` per pass**, same
  contract as `WetoShared`. `KillReporting` carries a `KillContext` — reason, geo readout,
  diagnostics — instead of a bare `&str`. `Journal::refine_episode` rewrites every record of the
  episode; `refine_basis` rewrites only the records of one `MatchBasis`. A record's `id` is
  `{episode}-{n}` and `n` keeps counting across the passes of one episode (`StandingEpisode` in
  `state.rs`): a pause lasts, and a target that joins it on a second pass — born under the pause,
  or resumed and stopped again — would otherwise repeat `{episode}-0`. macOS gives every record
  a UUID, and `id` is part of the shared export format.
- **Everything weto sends `SIGSTOP` is explainable from the journal alone.** `KillReporting::paused`
  takes the targets, their descendants and the shell dragged along for the terminal
  (`MatchBasis::Shell`, named after the target it stood for); `recovered` opens its own episode for
  processes found standing at start-up, dated when they stopped rather than when weto noticed;
  `pause_resolved` appends the outcome to both. One episode per standing, no second record for the
  same pid, and a shell released while its target is killed gets «продолжен …» instead of
  «завершено» — it is alive. The reason "not verified yet" no longer exists as a journal entry:
  «Проверка» does not touch targets, so a kill is explained by its real cause from the first record.
- **Terminating uses `SIGKILL`, not `SIGTERM`.** A stopped process runs no handler, so `SIGTERM`
  would queue until something resumed it and the target would stay alive and frozen. The canon
  names `SIGKILL` for both platforms, so the boundary does not offer a soft signal at all:
  `ProcessSignal` is `Kill` / `Stop` / `Resume`, and a `Terminate` variant nothing sent was
  removed rather than left as an invitation.
- The episode ledger lives in `weto_core::episode::EpisodeLedger`, not in the app layer:
  the rule is identical on both platforms, and the app crate is all but untestable — a mistake in
  it showed up only on a live machine, as "launch blocked" records for a process killed for the
  first time. What little of it can be tested is tested in place (`#[cfg(test)] mod tests` in
  `state.rs` and `main.rs`): per-record journal ids and the exit funnel.
  `episode_finished` fires on **every** transition to safe, not just for an episode
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
- **The stable path is the launch symlink, `~/.local/bin/weto`** (`Paths::launcher`, written
  literally the way `install.sh` writes it). Anything outside the running process that has to name
  the binary means that symlink, never the versioned directory: the autostart entry writes
  `paths.launcher` rather than `current_exe()` (on Linux that resolves through `/proc/self/exe` and
  is therefore versioned, so after two updates it pointed at a pruned directory and the session
  started nothing), and `uninstall.sh` finds the running copy with `pgrep -x weto` plus a
  `/proc/<pid>/exe` check under the data directory, because the process is launched through the
  symlink and a `pkill -f` on the `current` path matched nothing. Both are covered by
  `scripts/tests/install-contract.sh` and `weto-sys/tests/autostart.rs`; see
  `bugs/launch-path-is-the-symlink-not-the-version.md`.
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

`shared/fixtures/guard-transitions.json` does the same for the reducer, and it is read here too
(`weto-core/tests/guard_transition_fixtures.rs`): the policy answers about one moment, but a
divergence between the implementations lives in the transitions.

## Testing

397 tests, run in a Linux container (`linux/scripts/dev.sh`). Two contracts need
`CAP_NET_ADMIN` because they create interfaces and routing rules:
`policy-routing-contract.sh` and `netlink-events-contract.sh`. The notification and the terminal
lookup are tested against a real session bus: the test starts its own `dbus-daemon`, serves a fake
`org.freedesktop.Notifications` and a fake `org.freedesktop.Application`, and checks the wording,
the action and the choice of ancestor (`weto-sys/tests/notifications.rs`, `tests/terminal.rs`).
Everything that cannot be faked — a real WireGuard tunnel, the look of the tray icon, a window
actually coming to the front — is covered by the checklists in `linux/docs/manual-check.md`
and `linux/docs/manual-ui-check.md`.

The hold is tested in two files on purpose: the rule itself is pure (`weto-app/tests/lifecycle.rs`,
no display), while `tests/held_window.rs` runs a real `Application` and asserts all three halves at
once — the app outlives its last window, `active_window` is then empty so a tray click takes the
"build a new one" branch, and `quit` still arrives at `connect_shutdown`, where the resume lives.
It is a separate file because it is a separate process: GTK initialises once, from one thread, and
the runner is parallel.

## Sibling crates

| Crate | Responsibility |
|---|---|
| `weto-ui` | design system on plain GTK4; two generated stylesheets, one per theme |
| `weto-tray` | StatusNotifierItem icon rendered from the shared `.icon` bundle |
| `weto-update` | release check, show policy, install into `$HOME`, rollback |
| `weto-app` | `weto` binary: status window, settings, update banner and window |

## How a pause plays out here

`GuardController` owns the reducer and does what it decides; there is no VM layer between
them, so the rules stay under test.

Feeding the reducer and applying its decision are two different steps, and they happen a different
number of times. `feed()` hands the reducer one input and touches nothing else; a tick may feed two
(`Reassessment` when the VPN app came back, then `Tick`), because knowledge about the exit changes
more than once in a second. `enforce()` runs **once**, after the last input of that pass, against
one scan — and that scan is the pass's only read of `/proc`. `run()` takes it before anything
else and hands it down: `vpn_app_status` (`is_running_in`), the pause plan and its signals, the
ledger observation, the running list on screen and `kill_context` all answer from the same
snapshot. They used to read for themselves, which cost a tick about three walks; the cost is the
smaller half of it, because a second read describes a second moment and a journal record would then
explain a kill with evidence from one instant and a VPN-app status from another. The only walk that
still happens on its own is the fallback inside the enforcer for a pass with no rules at all, where
`scan()` deliberately walks nothing: the ledger obligation does not depend on targets existing, and
a live VPN app must not look closed because the list it was matched against was empty. `dispatch()` is just the two together, for the paths whose input arrives outside the tick
loop — local evidence of a closed VPN client, which has to reach the targets before the network
rather than after five seconds of ipinfo timeout. A second enforcement inside one tick would signal
from data the first one had already changed: a target released by the first pass was declared
observed-running by the second, in the same tick that sent it its `SIGCONT`, although the obligation
is supposed to outlive the pass that signals it.

**The probe runs on its own track, and its answer is its own pass.** `start_probe` takes the
one-at-a-time gate (`ProbeGate`), records the revision and the fingerprint of that moment, and hands
the request to `BackgroundDispatching` — a thread in the app, a queue the test drains in the
harness. The pass returns without waiting; the request is the last thing it starts, after
`enforce()`. When the answer lands, `apply_probe` checks both barriers (a stale revision is
`discardedSettingsChanged`, a changed path `discardedPathChanged`, and both leave a record in the
checks journal), stores the reading, feeds `Verdict` and enforces — one input, one application,
exactly like a tick. Until this, the request ran inside the tick: the guard thread is the only
thing that ticks, so a target launched under a pause or under the ban lived for the whole ipinfo
timeout — five seconds on a dead channel — because nobody was left to apply anything. macOS never
had that gap (the probe is a `Task`, `applyLatestNetworkOutcome` is the second pass); this is the
port of it. The flying probe is never cancelled and never duplicated: while the verdict is stale
every tick asks again, and cancelling would mean the verdict never arrives on a slow channel. A skip
is recorded only for the button — automatic reasons ask every tick, and their skips would push the
one record the journal is kept for out of its fifty.

1. A probe answers *unproven* → the phase becomes `Paused`, whose action is `Pause`.
   `ProcessEnforcer::pause` builds the plan (`pause_plan::plan`) and sends `SIGSTOP` in order —
   shell, target, descendants — writing every delivered pid into `stopped.json`. Processes the user
   had already stopped (`T`) are in `plan.skipped` and get nothing. `StoppedLedger::add` keys on pid
   **and** path, like everything else that identifies an entry: an entry with the same pid but
   another path is a dead owner of a recycled number, so the fresh record replaces it at the tail
   (the ledger is the stop order).

   `enforce()` applies **the current phase's action on every pass**, not the transition effect the
   reducer returned. A target launched while the guard already stands causes no transition, and
   nothing else can catch it — a launch event would need `CAP_NET_ADMIN` — which is exactly what the
   250 ms tick under a red status is for. Same shape as macOS `GuardVM.applyCurrentAction`, driven
   there by the watchdog. A newcomer joins the episode that is already open: it brings no reason of
   its own, a pid already described gets no second record, its plan keeps the shell → target →
   descendants order, and its ledger entry lands at the tail in stop order. Under `Danger` the same
   re-application **is** the launch ban: `terminate_targets` runs each pass and kills whatever now
   matches, with the episode's evidence as the reason.
   Each such pass also asks whether the ledger still has a reason to hold what it holds:
   `ProcessEnforcer::release` frees every live entry that matches nothing under the current rules —
   the user removed its target, and weto has no business holding a process it no longer guards, let
   alone until the ceiling. A shell is released only when no non-shell entry is still guarded (it
   stands for its target's terminal; freeing it first hands the terminal back and the target lands
   on `SIGTTIN`), signals go in the same reverse stop order, and the entry leaves the ledger by
   observation like any other. The record gets its own outcome — `RELEASE_SIGNALLED_TEXT` when the
   signal went out, `RELEASED_TEXT` once observed, both word for word with macOS — and
   `pause_resolved` skips those pids so the episode's outcome cannot overwrite them.
2. Every tick re-announces the loss if the verdict is stale, but the ceiling counts from the bad
   result: `GuardInput::Tick` is the only thing that expires it, and a repeated announcement cannot
   restart it. At 60 s the phase becomes `Danger(PauseExpired)` and the targets are killed.
3. A good answer moves the phase back to a `Run` action — but the obligation is discharged by observation,
   not by delivery. `settle_resume` runs on **every** pass with running targets while the ledger is
   non-empty: it sends `SIGCONT` bottom-up and strikes an entry off only once the kernel shows the
   process running (or gone). A real background job answers each `SIGCONT` with another stop; after
   `RESUME_RETRY_LIMIT` (3, same as macOS) observed stops it stops being signalled — `notify` in zsh
   would otherwise print `suspended (tty input)` once a second — but the entry stays on the books
   and the journal says «не возобновлено … командой fg», never «возобновлено».
4. `recover_stopped()` runs before the first tick: `SIGCONT` by identity (pid **and** path, because
   pids get reused), a `startupRecovery` / `standingProcessesRemain` record in the checks journal,
   and its own kill-journal episode. An unreadable ledger leaves a `ledgerUnreadable` record.
5. `shutdown()` resumes everything on a clean exit and admits it cannot observe the result: the
   outcome is «не подтверждено …, weto проверит их при следующем запуске». It hangs off one funnel —
   `application.connect_shutdown` in `main.rs` — because buttons are not an exit path: GApplication
   quits by itself once the last window is gone, and that route left the targets standing. A
   `SIGTERM` handler turns the session logout into the same `quit`, so it goes through the funnel
   too. The one hand-written call left is the uninstall button, where the order is load-bearing
   (resume before the ledger file is deleted); `shutdown()` is idempotent, and the second call at
   exit finds an empty ledger and does nothing. Idempotence and the exit flag live under one
   mutex — `GuardController::enforcement` — which every pass through `enforce()` (and
   `recover_stopped()`) holds while it applies a decision to processes. `feed()` takes it too: after
   the exit the reducer has no business moving either, or a tick arriving behind the exit would put
   `Пауза` back on a screen whose countdown nobody is counting any more. The guard runs in its own
   thread and `shutdown()` arrives from the GTK one: without those gates a tick already in flight
   sent its `SIGSTOP` **after** the final `SIGCONT`, and nothing was left to thaw the target — the
   ticks are over. A tick that arrives after the exit turns back at the gate, and the guard thread
   leaves its loop on `is_shut_down()` instead of spinning as a no-op. The gates cover the
   application only, not the probe: waiting behind a five-second ipinfo timeout would hang the
   exit. Lock order is always `enforcement` → `inner`.
6. **Uninstall is the one exit that has to observe the result.** Everywhere else an entry the exit
   could not resolve is handed to the next launch — the ledger file survives and
   `recover_stopped()` reads it — but after uninstall there is no next launch: the ledger goes with
   the app, and a process that never came back up from the last `SIGCONT` stays frozen forever. So
   the button calls `shutdown()` and then `GuardController::confirm_resumed`, which re-runs the
   same scan-and-resume road (`resume_from_ledger`, `skipping` deliberately empty, so entries the
   tick gave up on under `RESUME_RETRY_LIMIT` get one more signal) and returns whoever the kernel
   still shows standing. `settings_window.rs` drives it from `timeout_add_local`, six attempts
   300 ms apart — the same numbers as macOS `MaintenanceCard`, a `SIGCONT` that will land lands on
   the first one — and names the survivors by name and pid before offering «Удалить всё равно» /
   «Отмена». It takes no enforcement gate (a tick after the exit has nothing to do) and does **not**
   rewrite the episode outcome a second time: `shutdown()`'s «не подтверждено» is the record of
   that standing.

## Not here yet

Secret Service over D-Bus — the token lives in a `0600` file. Country flags and
per-target icons are not fetched, so the status window shows generic glyphs.

**The pause has a face now.** The status window builds its title, shield colour and the
three explanation lines straight from `GuardPhase` (`weto_core::presentation::shield_color`,
`explanation`, `should_explain` — the same texts as macOS `GuardVM.statusColor` and
`StatusPresentation.explanation`, word for word), and every standing target gets a pause
badge with a live countdown (`weto_ui::components::pause_badge`/`pause_countdown_text`),
the `fg` hint and the "Показать терминал" button where the emulator can be raised —
see "Raising the terminal" above.
