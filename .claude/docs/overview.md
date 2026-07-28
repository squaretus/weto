# System Overview

## Data Flows

### Guard cycle: network event → verdict → kill

1. **Trigger.** `Sources/WetoSystem/NetworkEventSource.swift` emits `.networkPath`
   (`NWPathMonitor`), `.dynamicStore` (`SCDynamicStore` keys: global IPv4, per-service IPv4,
   interface link), `.wake` and `.appLaunched(bundleID:)` (`NSWorkspace`). Independently
   `GuardVM.startTicking` emits `.tick` every `settings.pollIntervalSeconds` (default 5 s),
   and `SettingsStore.emit` → `GuardController.configurationChanged` bumps `revision`,
   drops `freshVerdict` and calls `evaluate()` directly. `pollIntervalSeconds` deliberately
   does not `emit` — changing the tick rate is not a configuration change for the verdict.
2. **One process scan per trigger.** `GuardVM.handle` calls `ProcessEnforcer.scan()` once,
   stores it in `currentScan` and publishes `runningTargets` for the UI. argv is read
   (`KERN_PROCARGS2`) only when at least one rule is `.script`. Rules are resolved
   (filesystem + LaunchServices) only when `settings.targets` changed.
   `.appLaunched` short-circuits: non-target bundle IDs return immediately, and if the state
   is already `.unsafe` the launch is killed off the same scan without re-evaluating.
3. **Local decision first.** `GuardController.evaluate` reads `settings.guardConfig` and
   `snapshotReader.snapshot()`, resolves VPN through `VPNStatusResolver`, then
   `GuardPolicy.decideLocal`. A local answer cancels any in-flight probe, records the verdict
   and is applied — VPN loss is visible from `SCDynamicStore` without any network call.
4. **Fail-closed before the verdict.** With no local answer, `beginNetworkVerification`
   compares `Verdict(revision, snapshot.fingerprint)` with `freshVerdict`. On mismatch
   (cold start, path change, settings edit) it applies `GuardPolicy.pendingVerification`
   — targets die *before* the first HTTP request. If the verdict is still fresh, the state is
   left untouched while the probe runs: otherwise the 5 s tick would re-enter
   `verificationPending` and kill targets on a perfectly healthy VPN. That is why freshness is
   the pair «config revision + network snapshot fingerprint» (`NetworkSnapshot.fingerprint`:
   service UUIDs, active interfaces, VPN qualification, owner of the default route) and not
   plain snapshot equality. The 300 ms debounce (`Constants.networkEventDebounceSeconds`)
   that follows only coalesces outgoing requests — the state is already fail-closed.
5. **Probe.** `GeoProbe.probe()`: Keychain token → ipinfo Lite (`v4.api.ipinfo.io`),
   `IPAddress.isValid` on the returned address *before* it goes into a URL, then confirmation
   `free.freeipapi.com` → `get.geojs.io` fallback. Nothing is cached.
6. **Apply.** `applyLatestNetworkOutcome` drops outcomes whose `revision` is stale, re-reads
   config and snapshot immediately before deciding (a slow probe must never resurrect `safe`),
   publishes the reading (`GuardVM.receive` prefetches the flag) and calls `GuardPolicy.decide`.
7. **Enforce.** `GuardVM.apply`: `.safe` cancels the watchdog and clears `recordedPIDs` /
   `recordedReasons`; `.kill` sets `.unsafe`, enforces and starts a 250 ms watchdog
   (`Constants.watchdogIntervalSeconds`) that re-runs `enforce` only — no re-evaluation and no
   new probe — until the state goes safe. This is the only way to catch terminal targets:
   `NSWorkspace` reports GUI apps only.
   `ProcessEnforcer.enforce` → `ProcessMatcher.matches` (rule hit plus `ProcessTree`
   descendants, which inherit the root's target name) → `ProcessKiller` `SIGKILL`;
   `ESRCH` counts as terminated, other errno values surface as `permissionFailure` in the UI.
8. **Record.** Only PIDs that were actually terminated are journalled, deduplicated by
   *both* pid and reason within an episode: a new reason writes `.terminated`, a repeat reason
   with a new pid writes `.launchBlocked`. `EventLogStore` is a 10-entry ring buffer in the
   `com.weto.shared` UserDefaults suite. `UserNotificationKillNotifier` silently no-ops
   without a bundle id (`swift run`, tests).

Files: `Sources/WetoSystem/NetworkEventSource.swift`, `Sources/WetoShared/GuardVM.swift`,
`Sources/WetoShared/GuardController.swift`, `Sources/WetoCore/GuardPolicy.swift`,
`Sources/WetoCore/Model/NetworkSnapshot.swift`, `Sources/WetoSystem/GeoProbe.swift`,
`Sources/WetoShared/ProcessEnforcer.swift`, `Sources/WetoCore/ProcessMatcher.swift`,
`Sources/WetoSystem/ProcessKiller.swift`, `Sources/WetoShared/EventLogStore.swift`.

### Update: HTTP check in the app, root install in the daemon

1. **Check.** `AppCoordinator.start` → `UpdateVM.startPeriodicCheck`: one check immediately,
   then every `Constants.updateCheckInterval` (6 h). The app queries GitHub itself over HTTP
   and compares with `Constants.appVersion` via `ReleaseParser.parse`; HTTP 404 → `.noReleases`.
2. **Surface.** `availableUpdate` is non-nil only for `.available` + `isNewer`, and feeds both
   the banner in `StatusPopupView` and the settings footer.
3. **Request.** `UpdateVM.installUpdate` first refuses locally when `downloadURL` is empty
   (a release with no `.pkg` asset): the daemon could not install it either, so nothing is asked
   of root — `installFailure` is set and the release page opens. Otherwise
   → `HelperUpdateInstaller.requestInstall`
   (`UpdateInstalling` boundary, so the app is testable without a live daemon) →
   `WetoXPCClient.helper` (mach service `com.weto.helper`, `.privileged`) →
   `UpdateService.install` → `helper.performUpdate()` **with no arguments**: no URL,
   no version, no path. `AnsweredOnce` collapses the two possible completions
   (connection error handler / daemon reply) into one. A `nil` result means «no daemon»:
   `installFailure` is shown and the release page is opened through
   `UpdateVM.validatedReleaseURL` (https + host `github.com` only).
4. **Authorize.** `HelperDelegate.listener` accepts a connection only if
   `ClientAuthorization.isAuthorized(pid:)` matches the client executable path against
   `/Applications/Weto.app/Contents/MacOS/WetoMenuBar` (dev-build suffixes compile in `DEBUG`
   only). No Developer ID exists, so there is no team-id requirement to check.
5. **Re-check under root.** `performUpdate` guards a single install with `isInstalling`, clears
   the previous `lastFailure`, and reads the version from
   `/Applications/Weto.app/Contents/Info.plist`. An unreadable or empty version aborts right
   there ("Не удалось прочитать версию установленного приложения") — degrading to `"0.0.0"`
   would make every release look newer and let root install on no basis. Then it runs its own
   `UpdateChecker.checkLatestRelease`, replies `nil` (= started) to the client
   immediately and only then downloads. `UpdateChecker.downloadPackage` requires
   `ReleasePackageURL.isTrusted`, stores into `/var/db/weto/updates` (dir 0700, pkg 0600 —
   never `/tmp`, where the package could be swapped between download and install) and runs
   `/usr/sbin/installer -pkg … -target /`; the package is deleted regardless of outcome.
6. **The installer removes both callers.** The new package's `preinstall` does
   `launchctl bootout system/com.weto.helper` and `killall WetoMenuBar` — the daemon kills
   itself and the app in the middle of its own install, which is why `isInstallingUpdate`
   normally never gets cleared on the success path.
   `postinstall` bootstraps both again.
7. **Failure comes back by polling.** Because the reply was sent before the download,
   a failed download or a failed `installer` cannot be reported through it. The daemon writes
   the reason into its in-memory `lastFailure` (`record(failure:)`), and
   `UpdateVM.startWatchingInstall` asks `requestLastFailure` → `lastInstallFailure` every
   `Constants.installOutcomePollSeconds` (5 s) while the spinner is up. A non-`nil` answer stops
   the spinner and shows the message; `nil` means "nothing to report" and is also what a dead
   daemon looks like. Success is still never reported — it is observed as the process dying.

Files: `Sources/WetoShared/UpdateVM.swift`, `Sources/WetoShared/UpdateInstalling.swift`,
`Sources/WetoXPC/WetoXPCClient.swift`, `Sources/WetoXPC/UpdateService.swift`,
`Sources/WetoHelper/HelperDelegate.swift`, `Sources/WetoHelper/ClientAuthorization.swift`,
`Sources/WetoHelper/UpdateChecker.swift`, `Sources/WetoCore/ReleasePackageURL.swift`,
`scripts/preinstall`, `scripts/postinstall`.

The XPC surface of this flow is exactly `performUpdate`, `lastInstallFailure`,
`uninstallHelper` — every method has a caller. The former check-over-XPC branch
(`checkForUpdate`, `checkForUpdateForced`, `getHelperVersion`) was removed: it had no callers
while being executed by a root process.

### Install and autostart: PKG → launchd → running copy

1. **Payload** (`scripts/build.sh`): `Applications/Weto.app`,
   `Library/PrivilegedHelperTools/com.weto.helper`,
   `Library/LaunchDaemons/com.weto.helper.plist`. The user agent plist is *not* packaged.
   A component plist pins `BundleIsRelocatable=false`, and the build verifies it by expanding
   the component pkg — otherwise Installer would drop the app next to an older copy.
2. **`scripts/preinstall`** (`set -u`, best effort): boots out `gui/<uid>/com.weto.app` for the
   console user, removes both `~/Library/LaunchAgents/com.weto.app.plist` and the legacy
   `/Library/LaunchAgents` one, boots out `system/com.weto.helper` (required before the binary
   is replaced), `killall WetoMenuBar`.
3. **`scripts/postinstall`** (`set -euo pipefail` — every failure aborts the install loudly):
   requires `/Applications/Weto.app/Contents/MacOS/WetoMenuBar` to be executable; resolves the
   console user from `stat -f '%Su' /dev/console` and the home directory from
   `dscl … NFSHomeDirectory` (never assembled as `/Users/<name>`); writes the agent plist
   (`Program` = that binary, `RunAtLoad`, `KeepAlive`), `chown` to the console user, 644;
   drops the legacy system agent; `launchctl asuser <uid> bootstrap gui/<uid>`; then
   `chown root:wheel` + `launchctl bootstrap system` for the daemon plist.
4. **The copy launchd starts.** `AppDelegate.applicationDidFinishLaunching` claims the
   `com.weto.app.singleton` CFMessagePort (a second copy terminates itself), sets the
   `.accessory` activation policy, calls `disableAutomaticTermination` /
   `disableSuddenTermination` (a windowless launchd copy is otherwise put to sleep, taking the
   guard with it) and then `coordinator.start()` — guard loop plus update loop.
5. **That copy *is* the job.** launchd puts `XPC_SERVICE_NAME=com.weto.app` in its environment,
   which `LaunchAgentController.isRunningAsAgent` detects: for such a process `enable()` only
   writes the plist and `disable()` only removes it. Any `bootout` of its own job would be
   `SIGTERM` to itself, so `bootout` is reserved for `Maintenance.closeApp`, which does intend
   to quit.

Files: `scripts/build.sh`, `scripts/preinstall`, `scripts/postinstall`,
`Resources/com.weto.helper.plist`, `Sources/WetoMenuBar/WetoMenuBarApp.swift`,
`Sources/WetoShared/LaunchAgentController.swift`, `Sources/WetoShared/AppCoordinator.swift`.
