# The launch path is the symlink, not the version directory (Linux)

## Symptoms
Two failures with one shape, both found by an external review of the Linux port:

- Autostart stops working after updates. The entry is still in `~/.config/autostart`, the toggle
  still reads "on", but the session starts an old copy after the first update and nothing at all
  after the second — so there is no guard after a reboot and nobody is told.
- Uninstall leaves weto running. The uninstaller deletes everything and the still-live process
  immediately recreates the directories it just removed, so the machine is neither clean nor
  un-guarded.

## Scope
Linux only: `weto-sys/src/autostart.rs`, `weto-config/src/paths.rs`, `linux/scripts/uninstall.sh`.
macOS has neither problem — there the bundle path is stable and the agent plist names it.

## Root cause
The install layout has three paths and only one of them is stable:
`~/.local/share/weto/<version>/bin/weto` (pruned), `…/weto/current/bin/weto` (a symlink the
installer moves) and `~/.local/bin/weto` (the symlink the user and the desktop actually launch).
Both bugs named one of the first two.

- The autostart entry was written from `std::env::current_exe()`. On Linux that is resolved through
  `/proc/self/exe`, so it is always the versioned path. The installer keeps the current version and
  one previous, and nothing rewrites the entry on update.
- `uninstall.sh` matched the command line: `pkill -f "$DATA/weto/current/bin/weto"`. The process is
  started through `~/.local/bin/weto`, so its `argv[0]` never contained `current` and `pkill`
  silently matched nothing — silently, because the line ended in `|| true`.

## Reproduction
1. Install, enable autostart, update twice (or delete the version directory named in
   `~/.config/autostart/weto.desktop`), log out and back in — no weto.
2. Launch weto through `~/.local/bin/weto`, run `uninstall.sh`, then `pgrep -x weto`.

## Fix
- `Paths::launcher` = `~/.local/bin/weto`, taken literally the way `install.sh` writes it
  (`BIN="$HOME/.local/bin"`) — the two must not drift, or the installer's own entry and the
  autostart entry point at different places. `Autostart` stores that path (`Autostart::rooted` now
  takes it explicitly, for tests) and writes it into `Exec=`.
- `uninstall.sh` iterates `pgrep -x weto` and kills only pids whose `readlink -f /proc/<pid>/exe`
  lives under the data directory: the process name plus proof that it is our file.

## Regression checks
- [ ] `linux/scripts/dev.sh bash scripts/tests/install-contract.sh` — the contract now starts a
      stand-in copy through `$BIN/weto` and fails if it survives the uninstall (a zombie does not
      count as alive; the state is read from `/proc/<pid>/status`).
- [ ] `linux/scripts/dev.sh cargo test -p weto-sys --test autostart` — the entry's `Exec=` is the
      launcher path, not the running executable.
- [ ] Any new reference to the weto binary outside the running process: it must be
      `Paths::launcher`.

## Related files
- `linux/crates/weto-config/src/paths.rs`
- `linux/crates/weto-sys/src/autostart.rs`
- `linux/scripts/uninstall.sh`, `linux/scripts/install.sh`
- `linux/scripts/tests/install-contract.sh`
