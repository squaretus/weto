# Install the terminal version (`weto`) on a server

Put the terminal version on a headless machine (Linux x86_64/aarch64 or macOS arm64), configure
it by commands and run it as a whole-machine service.

## Steps

### A. One command (from a published release)
1. Install binary + service:
   ```bash
   curl -fsSL https://github.com/squaretus/weto/releases/latest/download/install.sh | sudo bash
   # or: wget -qO- https://github.com/squaretus/weto/releases/latest/download/install.sh | sudo bash
   ```
   The script (`shared/cli/install.sh`) refuses without root, picks
   `weto-cli-<v>-<linux|macos>-<x86_64|aarch64|arm64>.tar.gz` by reading the release's
   `SHA256SUMS` (the "latest" URL does not know the version, the sums file does), verifies the
   sha256, installs `/usr/local/bin/weto` atomically (`.weto.new` + `mv`) and runs
   `weto service install`. Re-running it is a reinstall over the old one.
   Env: `WETO_VERSION=0.3.0` (pin/rollback), `WETO_PREFIX`, `WETO_NO_SERVICE=1`,
   `WETO_BASE_URL` (tests: `file://`). Pass them after `sudo`: `… | sudo WETO_VERSION=0.3.0 bash`.
2. Configure — **everything through `sudo`** (the guard reads root's storage):
   ```bash
   sudo weto token set                          # ipinfo token from stdin, no echo
   sudo weto target add claude                  # not in root's PATH → found in the caller's PATH
   sudo weto vpn list                           # interfaces; the traffic carrier is marked
   sudo weto vpn set wg0                        # app or tunnel detected; --app/--tunnel to force
   sudo weto blacklist add RU                   # country, IP or CIDR; whitelist is optional
   sudo weto timeout set 5                      # pause ceiling, minutes: 1|2|5|10
   ```
   The running service picks edits up by itself (no restart).
3. Verify without `sudo`: `weto status` (exit `0`; `3` — not running), `weto service status`.

### B. By hand (own build, or no release yet)
1. Build on the server's OS/arch:
   - Linux: `linux/scripts/build.sh <X.Y.Z>` → `linux/target/release_build/cli/weto-cli-<X.Y.Z>-linux-<arch>.tar.gz`
     (static musl, one file `weto`); dev build: `linux/scripts/dev.sh cargo build --release -p weto-cli`
     → `linux/target/release/weto-cli` (glibc, rename to `weto` when copying).
   - macOS: `macos/scripts/make-cli.sh release <X.Y.Z>` → `macos/.build/cli/weto` (ad-hoc signed)
     and `macos/.build/release_build/cli/weto-cli-<X.Y.Z>-macos-arm64.tar.gz`.
2. Copy to a stable place: `sudo install -m 0755 weto /usr/local/bin/weto`. Never install the
   service from `target/` or `.build/` — `service install` warns, the next build breaks it.
3. Optional dry run: `sudo weto run` (log to stdout, Ctrl-C = orderly exit, paused targets resumed).
4. `sudo weto service install`, then configure as in A.2.

Per-user mode (no `sudo`): same commands without `sudo`; storage under `~/.config/weto-cli` /
`~/Library/Application Support/weto-cli`, user unit `~/.config/systemd/user/weto.service` (needs
`loginctl enable-linger $USER`, the command hints it) or LaunchAgent `gui/<uid>/com.weto.cli`.

### Update / remove
- `weto update check` (no sudo), `sudo weto update` — downloads, verifies against `SHA256SUMS`,
  replaces the binary, restarts the service. Or re-run the one-line installer.
- `sudo weto service uninstall`; then `sudo rm /usr/local/bin/weto` and, to wipe state,
  Linux `/etc/weto`, `/var/lib/weto`; macOS `/Library/Application Support/weto`, root's
  `com.weto.cli` defaults. The stopped ledger survives `uninstall` and is processed by the next `run`.

## Common issues
- «охрана установлена на всю машину — sudo weto …» — a system install exists; repeat with `sudo`.
- `target add claude` under `sudo` → «не найдено» — neither root's nor the caller's `PATH` has it
  (or there is no `SUDO_USER`, e.g. a root login); add by full path.
- A user's target shows «не запущено» under a root guard in a container — the container lacks
  `CAP_SYS_PTRACE`, so root cannot read other users' `/proc/<pid>/exe`.
- macOS: a target under `/tmp` or `/var` is never matched (`/private` prefix stripped by symlink
  resolution) — known, open; put such binaries elsewhere.
- Installer: «в релизе нет терминальной версии для …» — the latest release is app-only; pin
  `WETO_VERSION`. «контрольная сумма … не совпала» — corrupted/swapped download, nothing installed.
- `weto update check` → «в последнем релизе <b> нет терминальной версии для этой системы» — same
  cause, code 0. «версия этой сборки неизвестна» — a `dev` build, cannot compare.
- Linux installer warns about `~/.local/bin/weto` of a user — that is the GUI app's command and may
  shadow `/usr/local/bin/weto` without `sudo`. Two guards never run together: `run` refuses while
  the app is open («запущено приложение Weto…»).
- «охрана уже запущена (pid N)» — the service holds `run.lock`; use `weto status`, not a second `run`.
- Targets die with «VPN-туннель wg0 не поднят» — interface not `UP`+`RUNNING` (`ip link show wg0`);
  «трафик идёт мимо туннеля wg0 — через eth0» — `ip route get <ipinfo ip>` leaves via eth0.
- `status` says not running while the service is active — `status.json` older than 10 s or pid
  dead; look in the log for «статус не записался».
- Service SIGKILLed after 15 s (`TimeoutStopSec`) — paused targets stay frozen until the next `run`.

## Where logs / metrics
- Linux: `journalctl -u weto -f` (system), `journalctl --user -u weto -f` (user).
- macOS: `/Library/Logs/weto.log` (system), `~/Library/Logs/weto.log` (user).
- Status: `weto status [--json]` — `/var/lib/weto/status.json` / `/Library/Application Support/weto/status.json`
  (user mode: `~/.local/state/weto-cli/`, `~/Library/Application Support/weto-cli/`).
- Journals: `sudo weto journal [--json]`; `journal.json`, `checks.json`, `stopped.json` next to `status.json`.
- New release noticed by the running guard: log line «доступна версия <b>: sudo weto update»,
  `updateAvailable` in `status.json`, last line of `weto status`.
