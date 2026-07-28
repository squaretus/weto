# WetoHelper (privileged update daemon)

## Purpose
The only root code in the project. `installer -pkg` requires root, so installing an update
cannot happen inside the sandboxed menu bar app. `com.weto.helper` runs as a system
LaunchDaemon, queries the GitHub release itself, downloads the `.pkg` into a root-owned
directory and installs it. The XPC surface is deliberately parameterless *and* narrow: the
client may only say "install an update" (never *which* one), ask how the last attempt ended,
or ask the daemon to remove itself.

## Key files
- `Sources/WetoHelper/main.swift`
- `Sources/WetoHelper/HelperDelegate.swift`
- `Sources/WetoHelper/ClientAuthorization.swift`
- `Sources/WetoHelper/UpdateChecker.swift`
- `Sources/WetoHelper/HelperLogger.swift`
- `Resources/com.weto.helper.plist`
- `scripts/preinstall`, `scripts/postinstall` (bootout/bootstrap of the daemon)
- `Sources/WetoCore/ReleasePackageURL.swift` (download host allowlist, lives in Core to stay testable)
- `Sources/WetoXPC/WetoHelperProtocol.swift`, `Sources/WetoXPC/WetoXPCClient.swift` (client side)

## Entry points
Mach service `com.weto.helper` (`NSXPCListener`, `MachServices` in the LaunchDaemon plist).
Protocol `WetoHelperProtocol` — three methods, each with a real caller in the app:
- `performUpdate(reply: (String?) -> Void)` — replies `nil` **before** download/install finish;
  the reply means "accepted", not "installed". Refuses early with a message when a second
  install is running, when the installed app's version cannot be read, when the release is not
  newer, or when the release has no `.pkg` (`UpdateChecker.UpdateError.noPackage`).
- `lastInstallFailure(reply: (String?) -> Void)` — the failure recorded *after* that `nil`
  reply, or `nil` if there was none. Called from `UpdateVM` on a 5 s poll while the spinner is up.
- `uninstallHelper(reply: (String?) -> Void)` — self-removal, then `launchctl bootout` of itself.

There is no version handshake and no release check over XPC: `getHelperVersion`,
`checkForUpdate` and `checkForUpdateForced` were removed because they had no callers while
being executed as root. Checking is `UpdateVM`'s job, over plain HTTP.
Callers: `WetoShared/UpdateInstalling.swift` (install + failure poll),
`WetoShared/Maintenance.swift` (uninstall).

## Dependencies
- launchd (system domain): `/Library/LaunchDaemons/com.weto.helper.plist`, `RunAtLoad` + `KeepAlive`.
- Binary location: `/Library/PrivilegedHelperTools/com.weto.helper` (root:wheel, 0755).
- External API: `https://api.github.com/repos/<owner>/<repo>/releases/latest` (30 s timeout).
- Download hosts: `github.com`, `objects.githubusercontent.com`, `release-assets.githubusercontent.com`.
- Binaries invoked: `/usr/sbin/installer`, `/bin/launchctl`.
- Reads `/Applications/Weto.app/Contents/Info.plist` (`CFBundleShortVersionString`).
- Libraries: `WetoCore` (`ReleaseParser`, `ReleasePackageURL`, `SemanticVersion`), `WetoXPC`, `libproc`.
- DB / queue: none.

## Side effects
<!-- generated, verify -->
- Filesystem: creates `/var/db/weto/updates` (0700), writes `weto-update.pkg` (0600),
  deletes the package after `installer` regardless of exit status.
- Runs `installer -pkg <path> -target /` — replaces `/Applications/Weto.app` and its own binary.
- `uninstallHelper` removes `/Library/LaunchDaemons/com.weto.helper.plist`,
  `/Library/PrivilegedHelperTools/com.weto.helper` and `/var/db/weto/updates`, then
  `launchctl bootout system/com.weto.helper` after a 0.3 s delay (bootout kills the process,
  so it must happen after the XPC reply).
- Logging: unified log, subsystem `com.weto.helper`, category `Helper`, messages marked
  `privacy: .public`. Verify no client path or URL logged there is considered sensitive.
- In-memory `lastFailure` string (`record(failure:)`), guarded by the same `NSLock` as
  `isInstalling`; never persisted. Cleared at the start of every `performUpdate`, so a stale
  failure cannot leak into a new attempt, and lost entirely when the daemon restarts.
  Nothing else is cached — the daemon no longer keeps the last `UpdateInfo`.

## Invariants / assumptions
<!-- generated, verify -->
- **`performUpdate` takes no parameters.** The daemon re-runs its own release check and uses
  only its own `downloadURL`. Accepting a URL or version from the client would mean any
  authorized process could ask root to install an arbitrary package.
- **Version compared is the installed app's**, read from `/Applications/Weto.app/Contents/Info.plist`,
  not the daemon's own build. `installedAppVersion` is `String?` and a missing, unparseable or
  empty `CFBundleShortVersionString` **stops the install** with "Не удалось прочитать версию
  установленного приложения". It must not degrade to `"0.0.0"`: that made every release look
  newer, i.e. root installed a package on no basis at all.
- **A failure after the `nil` reply must be recorded, not just logged.** `record(failure:)` is
  the only way the user can learn that the download or `installer` failed — the XPC reply is
  long gone. Any new terminal branch in `downloadAndInstall` needs the same call.
- **Download URL must pass `ReleasePackageURL.isTrusted`**: https + allowlisted GitHub delivery
  host + path ending in `.pkg`. The URL comes from a network response and is otherwise untrusted.
- **The package never passes through `/tmp`.** A world-writable staging path allows swapping
  the file between download and `installer`, and root would install someone else's package.
- **Authorization is by client executable path**, `proc_pidpath(pid)` compared against
  `/Applications/Weto.app/Contents/MacOS/WetoMenuBar` (plus `.build/...` suffixes, `#if DEBUG` only,
  absent from the release PKG). Honest boundary: the project has no Apple Developer ID, so
  `SecCodeCheckValidity` with a team-id requirement has nothing to verify against.
  This stops unrelated *user* processes from calling `performUpdate`. It does **not** protect
  against root — root can replace the binary at the allowed path, and there is a pid-reuse
  window between `processIdentifier` and the `proc_pidpath` lookup. Accepted limit: without root
  an attacker gains nothing through XPC they could not do directly. Replace with
  `SecCodeCheckValidity` once a Developer ID exists.
- `delegate` and `listener` in `main.swift` are global `let`s on purpose: `NSXPCListener.delegate`
  is weak, and a release build would free the delegate right after `resume()`.
- `isInstalling` allows one install at a time; it is reset in every terminal branch
  (`finishInstalling`) — including the failure paths of download and install.

## Failure hotspots
<!-- generated, verify -->
- **Install usually kills the caller and the daemon.** `preinstall` does
  `launchctl bootout system/com.weto.helper` and `killall WetoMenuBar`, so the process running
  the install dies mid-flight. The spinner in the UI going dark is the expected outcome, not an error;
  `WetoXPCClient` re-creates the connection after invalidation for this reason.
- **Install failure survives only in memory.** `downloadAndInstall` logs *and* records into
  `lastFailure`; the app has to ask for it within the daemon's lifetime. `KeepAlive` respawn,
  `bootout`, or a client that quits before the next 5 s poll all mean the message is never seen
  and only `log show --predicate 'subsystem == "com.weto.helper"'` still has it.
- Version drift after a manual/partial install: the daemon may keep running an old build while
  `/Applications/Weto.app` is new, since it compares against the app plist, not itself. With no
  version handshake left on the protocol, nothing detects that.
- `uninstallHelper` reports per-path failures as a joined string; a partial failure leaves the
  daemon loaded until the next boot.
- `postinstall` hard-fails if the helper binary or its plist is missing, or if
  `launchctl bootstrap system` refuses — deliberate, an unloadable daemon means no auto-update at all.

## Related docs
- `.claude/rules/ARCHITECTURE.md` — section `### Автообновление`, module index entry **WetoHelper**.
- `modules/weto-xpc.md` — the shared protocol and its client.
- `runbooks/release.md` — what a release must contain for this daemon to be able to install it.
