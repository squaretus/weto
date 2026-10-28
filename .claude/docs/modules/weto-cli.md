# weto — terminal version (both platforms)

## Purpose
A second shell over the existing guard backend for servers without a desktop: settings edited by
commands, the guard run in the foreground or as a systemd / launchd service, status and journal
read from the terminal, self-update from GitHub Releases. It is **not** a new guard — reducer,
pause, stopped ledger, journals and geo probes are reused as is. Two implementations, like the UI:
macOS over `WetoShared` (`GuardVM` + `SettingsStore`), Linux over `weto-guard`. Command grammar,
texts, exit codes and the `status.json` format are the same on both; the only platform differences
in texts are named ones (bundle id on macOS, systemd vs launchd). The only new guard capability is
choosing the VPN as a tunnel (interface name), which the GUI never offers.

The command and the shipped binary are called **`weto`**. Internal names stay: macOS target
`WetoCLI` (SPM product `weto`), Linux crate and cargo binary `weto-cli` (`weto` is taken by the
GTK app in the same workspace; `build.sh` renames it to `weto` in the archive), user storage
directories `weto-cli`, asset prefix `weto-cli-`.

## Key files
- macOS (`executableTarget WetoCLI`, product `weto`):
  - `macos/Sources/WetoCLI/WetoCLI.swift` — `@main`; main loop is `RunLoop.main.run()`, not
    `dispatchMain()` (`NetworkEventSource` hangs its `SCDynamicStore` source on the main run loop)
  - `CommandParser.swift` — hand-written parsing, full and per-object help, `--version`
  - `CLI.swift` — every command except `run`; `CLIEnvironment.live` picks the storage by euid;
    `systemInstallRefusal`; `vpnKind(of:…)` (VPN auto-detection)
  - `CLIPaths.swift` — `user(home:)` / `system(root:)`, `isInstalled`, `prepareSystemDirectory`
  - `GuardRunner.swift` — `run`: lock, app check, `GuardVM` assembly, signals, 250 ms observe timer,
    `GuardLog`, `LogNotifier`, `DetachedLaunchAgent`, `UpdateWatch`
  - `Update.swift` — `CLIUpdate` (asset name, `SHA256SUMS`, trusted hosts), `UpdateSource`,
    `TarArchiveUnpacker` (external `tar`), `BinaryReplacer`, `UpdateWatch` (daily check)
  - `GuardStatus.swift` (`status.json` model, atomic write, liveness), `StatusText.swift`
  - `ServiceManager.swift` — `com.weto.cli` plist text, idempotent `install`, `restartIfRunning`
  - `Boundaries.swift` — `WetoAppProcessDetector`, `GuardProcessSignaling`, `ServiceControlling`
  - `macos/scripts/make-cli.sh [debug|release] [version]` → `macos/.build/cli/weto`; with a
    version also `macos/.build/release_build/cli/weto-cli-<v>-macos-arm64.tar.gz`
- Linux (crate `weto-cli`; deps `weto-core`, `weto-config`, `weto-sys`, `weto-guard`, `weto-update`,
  `ureq` (rustls), `flate2`, `tar`, `sha2`, `libc`, `serde(_json)` — no gtk4, ksni, zbus, tokio):
  - `linux/crates/weto-cli/src/main.rs`, `lib.rs` (`main_with`, `execute`), `args.rs`
  - `commands.rs` — all commands except `run`; `detect_vpn_kind`; exit codes `OK/FAILURE/USAGE/NOT_RUNNING`
  - `context.rs` — `Context::from_env` (storage by euid), `system_install_seen_by_user`,
    `prepare_system_storage`, `restrict_umask`
  - `run.rs` — `RunLock`, `app_is_running`, `SignalPipe` (self-pipe), `AfterPass`, daily update check
  - `update.rs` — asset by name, `SHA256SUMS`, in-process unpack, `DiskBinary` replace, `UpdateWatch`
  - `status.rs`, `store.rs` (`Store`, `Store::public`, `WatchedSettings`), `service.rs`, `log.rs`
  - `weto-config/src/paths.rs` — `Paths::system()` / `system_under(root)`
  - `weto-guard/src/runtime.rs` — the loop and journal writers it shares with `weto-app`
  - `linux/scripts/build.sh <v>` → `linux/target/release_build/cli/weto-cli-<v>-linux-<uname -m>.tar.gz`
- Shared: `shared/cli/install.sh` (one-command installer, both OSes),
  `shared/cli/tests/install-contract.sh`
- Tests: `macos/Tests/WetoCLITests/` (incl. `SystemModeTests`, `UpdateTests`),
  `linux/crates/weto-cli/tests/{commands,run,service,status,system,update}.rs`

## Entry points
- Grammar `weto <object> <action> [value]`:
  `status [--json]`, `check`, `run`, `journal [--json]`;
  `target list|add|remove`, `vpn show|set [--app|--tunnel] <v>|clear|list`,
  `blacklist|whitelist list|add|remove`, `timeout show|set <1|2|5|10>`, `token show|set [<t>]|clear`,
  `service install|uninstall|status`, `update check|install` (bare `update` = `install`),
  `version` / `--version`, `help` / `--help` / `-h`.
  Gone: `vpn app|tunnel|tunnels` (→ `vpn set`, `vpn list`), `timeout [N]` (→ `timeout show|set`).
- `journal` prints one line per episode, like the window (`JournalEpisode` / `weto_config::journal::episodes`):
  «time  targets  summary», then «    Итог: …»; the latest 20, then «Показаны последние 20 из N —
  выгрузите журнал целиком: weto journal --json» (N counts episodes). Pids only in `--json`.
- Help: `weto <object> help` and `weto help <object>` → stdout, code 0; `weto <object>` with no
  action → the same help to stderr, code 2.
- Exit codes: `0` ok, `1` failure, `2` bad arguments, `3` guard not running (`status`, `check`).
- `SIGTERM`/`SIGINT` to `run` — orderly exit; `SIGUSR1` — connectivity check (trigger «нажатие»).

## Dependencies
- macOS: `WetoCore`, `WetoSystem`, `WetoShared`, `WetoDesign` (only `WetoPauseBadge.remainingText`),
  `UpdateKitCore` (`SemanticVersion`, delivery host list), `CryptoKit`. No `AppKit`:
  `module-boundary-contract.sh` pins the import list and forbids `UNUserNotificationCenter`,
  `NSRunningApplication` and `NSWorkspace` in `Sources/WetoCLI`.
- Linux: `weto_guard::runtime`, `weto_sys::target_resolver::settings_target`, `weto_update`
  (version compare, trusted hosts — must not drift from the app updater).
- External commands (behind boundaries): `systemctl [--user]`, `loginctl show-user`, `launchctl`,
  macOS `tar`.
- Network: `api.github.com/repos/squaretus/weto/releases/latest` (with `User-Agent`) + asset downloads.

## Side effects
- Storage — chosen by **effective uid**, never by `$HOME`
  (`decisions/whole-machine-guard-from-root.md`), separate from the app entirely:

  | | macOS | Linux |
  |---|---|---|
  | euid 0: settings | suite `com.weto.cli` of root (`/var/root`) | `/etc/weto/config.toml` `0644` |
  | euid 0: token | `/Library/Application Support/weto/token` `0600` | `/etc/weto/token` `0600` |
  | euid 0: journals, ledger, lock | `/Library/Application Support/weto/` `0600` | `/var/lib/weto/` `0600` |
  | euid 0: `status.json` | same dir, `0644` (dir `0755`) | `/var/lib/weto/status.json` `0644` |
  | user: settings | suite `com.weto.cli` of the user | `~/.config/weto-cli/config.toml` |
  | user: the rest | `~/Library/Application Support/weto-cli/` | token `~/.config/weto-cli/token`, rest `~/.local/state/weto-cli/` |

  Under root the process runs with umask `077`; public files and dirs get their modes explicitly.
- `run` writes `status.json` atomically (temp + rename) once a second and on every phase change,
  removes it on orderly exit. One log line per phase change, journal event, outcome and new
  release version.
- `service install`: Linux root → `/etc/systemd/system/weto.service` (`WantedBy=multi-user.target`,
  no `Environment=HOME`), user → `~/.config/systemd/user/weto.service`; `daemon-reload`, `enable`,
  then `restart` if active else `start`. macOS root → `/Library/LaunchDaemons/com.weto.cli.plist`
  (`0644`, `launchctl bootstrap system`, log `/Library/Logs/weto.log`), user →
  `~/Library/LaunchAgents/com.weto.cli.plist` (`gui/<uid>`, log `~/Library/Logs/weto.log`).
  Same plist and loaded → `kickstart -k`; different → `bootout` + `bootstrap`.
  `uninstall` stops, disables and deletes the file; the stopped ledger stays for the next `run`.
- `update install` replaces the binary at the symlink-resolved path of the running executable
  (`.weto.new` `0755` + `rename`), then restarts the service if it is running
  (`systemctl [--user] restart weto.service` / `launchctl kickstart -k`). macOS only: under `sudo`
  with no system service running it restarts the caller's (`SUDO_UID`) LaunchAgent instead.
- The running guard asks GitHub 60 s after start and then every 24 h; never installs anything.
- `check` against a running guard sends `SIGUSR1` to the pid from `status.json`; without one it
  makes one probe in its own process and signals nobody.

## Invariants / assumptions
- **One guard per set of targets.** `run` takes `flock` on `run.lock` (released by the kernel even
  on SIGKILL). A user guard refuses to start while its GUI app runs; a root guard detects the app
  of **any** user but only logs a warning and keeps guarding — the marker is a path any user can
  fake, and refusing would hand them an off switch for the whole-machine guard: macOS walks the process table for `…/Weto.app/Contents/MacOS/…`
  (a LaunchDaemon has no window session for `NSRunningApplication`); Linux looks for a
  `/proc/<pid>/exe` under any `*/.local/share/weto/` (non-root can only see its own).
- **System install seen by a non-root user** (macOS: LaunchDaemon plist or the system data dir
  exists; Linux: `/etc/weto` or the system unit exists): open are `status` (reads the system
  `status.json`), `service status`, `update check`, `version`, `help`; everything else answers
  «охрана установлена на всю машину — sudo weto <args as typed>», code 1. `token set <t>` is
  echoed back as `token set` only — the token never lands in the hint. Only writing commands
  create the system dirs: the dir is the install marker, and `sudo weto version` must not plant it.
- **`vpn set` auto-detection** (same order on both): flag → `/` or `.app` = app → name of an
  existing interface (up or not) = tunnel → resolves as a target = app → valid interface name =
  tunnel with a «нет сейчас» warning → else «не найдено ни приложения, ни сетевого интерфейса…»,
  code 1. Interfaces are asked before programs: `wg0` may also be a command in `PATH`.
- **Choosing a tunnel clears the app and vice versa** (setters on both platforms). A target equal
  to the VPN app is refused with the window's text. Tunnel name — 1–15 chars `[A-Za-z0-9_.-]`.
- **Settings edits travel by file, not by IPC.** Linux: `Store` + revision bump (timeout without);
  the guard re-reads by file stamp (mtime, length, inode) once a pass, a corrupt file keeps the old
  settings and logs once. macOS: `SettingsStore` setters; the guard calls `reloadFromDefaults()`
  once a second (`modules/weto-shared.md`).
- **Liveness is "fresh file AND live pid".** `status.json` older than 10 s or a dead pid → not
  running (exit `3`). `kill(pid,0)` → `EPERM` counts as alive (a root guard seen by a user).
- **`status.json` (`version: 1`) is a shared format.** Absent values are `null`, not omitted;
  `updateAvailable` is a version string or `null`, decoded leniently from older files.
- **Update trust chain:** asset by exact name, https on GitHub delivery hosts only, sha256 from the
  same release's `SHA256SUMS`, archive must hold exactly one non-empty file `weto`. Any refusal
  before `rename` leaves the binary untouched («… — ничего не заменено»). Build version `dev` /
  `0.0.0` → «версия этой сборки неизвестна», code 1; the running guard then never checks.
- **A release without this platform's archive is not "available"** — neither for `update check`
  («в последнем релизе <b> нет терминальной версии для этой системы», code 0) nor for the guard's
  `updateAvailable`. App-only releases exist and will keep existing.
- **No desktop notifications at all.** Banners go to the log; kills are logged from the journal.
- **Service units:** systemd `Restart=on-failure` (`systemctl stop` is SIGTERM → exit 0),
  `TimeoutStopSec=15` (the default 90 s ends in SIGKILL, which cannot resume paused targets),
  `After=network-online.target`. launchd: `KeepAlive {SuccessfulExit: false}`,
  `ProcessType Interactive` (background type throttles timers — the App Nap trap), `RunAtLoad`.
  `com.weto.cli` is its own job; the "autostart is exactly one file" rule of `com.weto.app` does
  not apply. `install` is idempotent: the installer calls it on every run.
- **Under root no GUI-session APIs:** `NetworkEventSource(observesWorkspace: false)`; terminal
  polling already covers targets.

## Failure hotspots
- **Bare target names under root.** `sudo` brings root's `PATH`, without the user's `~/.local/bin`
  or version-manager shims. A name root cannot find is looked up in the `PATH` of `SUDO_USER`
  (`UserPathLookup` / `UserSearchPathProviding`: `runuser -l`/`su -l` login shell with a 3 s timeout,
  then `~/.local/bin`, `~/bin`, `~/.cargo/bin`, `~/.bun/bin`, `~/.deno/bin`, `~/.npm-global/bin`,
  on macOS also `/opt/homebrew/bin`, `/usr/local/bin`) and stored as the unresolved absolute path;
  output gains «найдено в PATH пользователя <u>: <путь>». Same for the app branch of `vpn set`.
  Without `SUDO_USER` (a root login) only root's `PATH` is used. Verified live on Linux only.
  The same goes for a user service under systemd — `target add` stores the `PATH` file in
  `launch_paths`, a hand-written config with a bare name may not resolve.
- **macOS `/private` prefix (known, not fixed, tracked separately).** `resolvingSymlinksInPath`
  strips `/private`, so a target under `/tmp` or `/var` never equals the process path from
  `proc_pidpath` (`/private/tmp/…`). Affects the GUI as well.
- **macOS root suite through `sudo` with a preserved `HOME` — not verified live.** The assumption
  that `sudo weto …` and the LaunchDaemon share root's `com.weto.cli` rests on `cfprefsd` keying
  domains by euid. If edits do not reach the daemon, check this first.
- **`make-cli.sh` embeds `Info.plist` in `__TEXT,__info_plist` without `CFBundleIdentifier` on
  purpose** — it would equal the suite name `com.weto.cli`, and `UserDefaults` refuses a suite
  named like its own bundle: settings would silently go nowhere.
- **Linux CLI must be static (musl).** A glibc build from the `ubuntu-24.04` runner needs
  `GLIBC_2.39` and does not start on Debian 12 / Ubuntu 22.04; `build.sh` fails on a dynamic
  binary (`ldd`). TLS is rustls — adding a crate that needs libssl breaks the musl build.
- **macOS archive metadata.** `tar` must run with `COPYFILE_DISABLE=1 --no-mac-metadata
  --no-xattrs`, otherwise `._weto` lands in the archive and both `weto update` and the installer
  reject it («внутри должен быть ровно один файл weto»).
- **Update restart asymmetry.** macOS falls back to the `SUDO_UID` user agent when no system
  service runs; Linux restarts only the scope it is running in.
- **One-shot commands and the carrier.** macOS `CLI.settledSnapshot()` waits for the route carrier
  (`vpn show`, `vpn list`, offline `check`); otherwise it reports that nothing leaves the machine.
- **`check` waits up to 15 s for `lastProbeAt` to change** (Linux `probed_at`, set after the answer
  is applied, including a discarded one). A guard that never answers looks like a timeout.

## Related docs
- features/terminal-version.md
- decisions/vpn-tunnel-in-terminal-version.md, decisions/whole-machine-guard-from-root.md
- runbooks/install-weto-cli-on-a-server.md, runbooks/release.md
- modules/weto-shared.md, modules/linux-guard.md, modules/weto-core.md
