# Decision: the terminal version guards the whole machine from root; storage is chosen by euid

## Problem
The first cut of the terminal version kept everything under `$HOME` (`~/.config/weto-cli`,
`~/Library/Application Support/weto-cli`) and allowed a root systemd unit only as "a user whose
home happens to be `/root`". On a server that broke in three ways:
- **`$HOME` under `sudo` is not stable.** macOS `sudo` keeps the caller's `HOME`; Linux depends on
  `sudoers` (`env_reset`, `always_set_home`). A root process choosing paths by `$HOME` wrote into
  the user's directory, and the service read another one.
- **A system unit has no `HOME` at all** unless it sets `User=` (systemd.exec(5)); the first cut
  had to bake `Environment=HOME=<installer's home>` into the unit, fragile and invisible.
- **A user service guards only that user's processes** and dies with the last ssh session unless
  linger is on. A server operator wants targets of any user stopped, without a login.

## Decision
- **Effective uid picks the storage, never `$HOME`.** euid 0 → fixed system paths:
  Linux `/etc/weto/{config.toml 0644, token 0600}`, `/var/lib/weto/{journal,checks,stopped}.json 0600`,
  `status.json 0644`, `run.lock`; macOS suite `com.weto.cli` of root (cfprefsd keys domains by
  euid) plus `/Library/Application Support/weto/` (token, journals `0600`, `status.json` `0644`,
  dir `0755`). euid ≠ 0 → the per-user storage from the first cut, for development and user
  services. The root process runs with umask `077`; public files get their modes explicitly.
- **`service install` from root installs a system service**: `/etc/systemd/system/weto.service`
  (`multi-user.target`, no `HOME`) / `/Library/LaunchDaemons/com.weto.cli.plist`
  (`launchctl bootstrap system`, log `/Library/Logs/weto.log`). It is idempotent, so the
  one-command installer (`shared/cli/install.sh`, always under `sudo`) simply calls it every time.
- **A non-root user beside a system install** is pointed at `sudo`: open are `status` (the system
  `status.json` is world-readable), `service status`, `update check`, `version`, `help`; every
  other command answers «охрана установлена на всю машину — sudo weto <args>» (code 1). The
  marker is the system config dir or the system service file — so only writing commands may
  create the dir.
- **The GUI app is looked for at every user, but a root guard never refuses because of it**:
  process-table walk on both platforms (`…/Weto.app/Contents/MacOS/…`, `/proc/<pid>/exe` under
  any `*/.local/share/weto/`). Both markers are paths any unprivileged user can create, so a
  refusal would let anyone switch the whole-machine guard off by running a fake «app» — the root
  guard logs a warning and keeps guarding (`app_conflict` / `GuardRunner.appConflict`); only a
  user guard refuses, where faking the app is self-inflicted.
  A LaunchDaemon has no window session, so no `NSRunningApplication` / `NSWorkspace` in `WetoCLI`
  at all (enforced by `module-boundary-contract.sh`).

## Reasoning
- euid is the one identity both `sudo weto target add …` and the service process agree on,
  whatever `sudo` does with the environment. Fixed paths make the unit self-contained.
- Readable `status.json` keeps the everyday question ("is it guarding?") free of `sudo`; the token
  and journals (raw geo answers, process paths of all users) stay root-only.
- Refusing edits from non-root rather than silently writing the user's own storage: the guard
  would never read that storage, and the user would believe the target was guarded.
- The app-detection walk must cover all users because a root guard stops all users' targets; two
  guards over one process fight with SIGSTOP/SIGCONT.

## Consequences
- **Bare target names under `sudo`.** Root's `PATH` lacks `~/.local/bin` and version-manager shims,
  so a name root cannot find is looked up in the `PATH` of `SUDO_USER` (login shell, then common
  per-user bin directories) and stored as the absolute path *without* resolving symlinks —
  `~/.local/bin/claude` survives updates of the version behind it. The user writes
  `sudo weto target add claude`; the third output line says where it was found.
- **macOS root suite through `sudo` with a preserved `HOME` is a reasoned assumption, not a
  verified one** (cfprefsd behaviour). If `sudo weto …` edits never reach the LaunchDaemon, check
  this first.
- The user-mode storage keeps its old `weto-cli` names; only the system paths use `weto`.
- macOS `update install` from `sudo` restarts the caller's user agent when no system service runs;
  Linux does not — a known asymmetry.
- Root is the expected mode for the terminal version, unlike the GUI app (Linux: "no root
  anywhere"; macOS: root only in `com.weto.helper`). This applies to the CLI only.
