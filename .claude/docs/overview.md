# System Overview

## Data Flows

### Guard cycle: network event → verdict → kill

1. **Trigger.** `macos/Sources/WetoSystem/NetworkEventSource.swift` emits `.networkPath`
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
   compares `Verdict(revision, snapshot.verdictFingerprint(forService:))` with `freshVerdict`. On mismatch
   (cold start, path change, settings edit) it applies `GuardPolicy.pendingVerification`
   — targets die *before* the first HTTP request. If the verdict is still fresh, the state is
   left untouched while the probe runs: otherwise the 5 s tick would re-enter
   `verificationPending` and kill targets on a perfectly healthy VPN. That is why freshness is
   the pair «config revision + network snapshot fingerprint»
   (`NetworkSnapshot.verdictFingerprint(forService:)`: the chosen service's active interface and
   VPN qualification, plus the owner of the default route) and not plain snapshot equality. The
   fingerprint is scoped to the chosen service on purpose — with the machine-wide one, a second
   VPN reconnecting beside the chosen tunnel killed the targets. The 300 ms debounce (`Constants.networkEventDebounceSeconds`)
   that follows only coalesces outgoing requests — the state is already fail-closed.
5. **Probe.** `GeoProbe.probe()`: Keychain token → ipinfo Lite (`v4.api.ipinfo.io`),
   `IPAddress.isValid` on the returned address *before* it goes into a URL, then confirmation
   `free.freeipapi.com` → `get.geojs.io` fallback. Nothing is cached. The return value is a
   `GeoProbeReport` — per-source outcome, `NWPathMonitor` path flag, timestamp — and the guard
   verdict is `report.outcome`, so the popup and the enforcement read the same object.
   A press of the popup's recheck button enters here through `GuardController.probeNow()`:
   no debounce, and freshness is deliberately *not* invalidated, so the press cannot kill
   targets on a healthy VPN. The press also bypasses the local short-circuit: even with the
   VPN down or the guard off, the request goes out — the local decision is applied first, then
   the report arrives and fills the popup. Without an ipinfo token the probe asks
   `get.geojs.io/v1/ip/country.json` about the caller and reports that country as the
   confirmation line; `report.outcome` still requires ipinfo, so the verdict stays fail-closed.
6. **Apply.** `applyLatestNetworkOutcome` drops outcomes whose `revision` is stale, re-reads
   config and snapshot immediately before deciding (a slow probe must never resurrect `safe`),
   publishes the report (`GuardVM.receive` keeps `lastReport`, prefetches the flag when the
   reading resolved) and calls `GuardPolicy.decide`.
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

Files: `macos/Sources/WetoSystem/NetworkEventSource.swift`, `macos/Sources/WetoShared/GuardVM.swift`,
`macos/Sources/WetoShared/GuardController.swift`, `macos/Sources/WetoCore/GuardPolicy.swift`,
`macos/Sources/WetoCore/Model/NetworkSnapshot.swift`, `macos/Sources/WetoSystem/GeoProbe.swift`,
`macos/Sources/WetoShared/ProcessEnforcer.swift`, `macos/Sources/WetoCore/ProcessMatcher.swift`,
`macos/Sources/WetoSystem/ProcessKiller.swift`, `macos/Sources/WetoShared/EventLogStore.swift`.

### Update: HTTP check in the app, root install in the daemon

The whole mechanism lives in `macos/Packages/UpdateKit` and is driven by `UpdateFeedConfiguration`;
weto contributes the configuration value, the dialog theme and the daemon entry point.
Module doc: `modules/update-kit.md`.

1. **Check.** `AppCoordinator.start` → `UpdateController.start`: one check immediately, then
   every `UpdateFeedConfiguration.checkInterval` (1 h). The app queries GitHub itself over HTTP
   and compares with `Constants.appVersion` via `ReleaseParser.parse`; HTTP 404 → `.noReleases`.
2. **Decide.** `UpdatePolicy.decide(latest:deferral:now:)` — a pure function over the release,
   the stored deferral and the clock — answers `silent`, `prompt` or `install`:
   - the version equals `skippedVersion` → silent (a higher version clears the skip by itself);
   - `remindAt` is in the future and no further than six hours ahead → silent (a date beyond
     that is treated as expired, so moving the clock back cannot lock updates away);
   - auto-install is on → install, with no dialog at all;
   - otherwise → prompt.
   A manual check (`checkNow`, the settings footer button) passes `prompt` unconditionally,
   ignoring both skip and reminder. That is the only way back to a skipped version.
3. **Surface.** `prompt` raises `isDialogPresented`; `UpdateWindowPresenter` (subscribed through
   `presentationHandler`) shows an `NSWindow` hosting `UpdateDialogView`, skinned by
   `WetoUpdateTheme`. `bannerUpdate` feeds the popup banner and is `nil` while the verdict is
   silent, so a skipped or deferred version hides the banner too. What the dialog shows is
   `UpdateDialogModel.make(info:progress:strings:)` — a pure value, tested without SwiftUI.
   Skip stores the version, "remind later" stores an absolute date (1/3/6 h), closing the window
   equals three hours.
4. **Request.** `UpdateController.install` first refuses locally when `downloadURL` is empty
   (a release with no `.pkg` asset): the daemon could not install it either, so nothing is asked
   of root — the failure phase is shown and the release page opens. Otherwise
   → `HelperUpdateInstaller.requestInstall` (`UpdateInstalling` boundary, so the app is testable
   without a live daemon) → `UpdaterXPCClient.helper` (mach service `com.weto.helper`,
   `.privileged`) → `UpdaterService.install` → `helper.performUpdate()` **with no arguments**:
   no URL, no version, no path. `AnsweredOnce` collapses the two possible completions
   (connection error handler / daemon reply) into one. A `nil` result means «no daemon»: the
   message is shown and the release page is opened through `UpdateController.validatedReleaseURL`
   (https + host `github.com` only).
5. **Authorize.** `UpdaterHelperService.listener` accepts a connection only if
   `ClientAuthorization.isAuthorized(pid:)` matches the client executable path against
   `configuration.clientExecutablePaths` (dev-build suffixes compile in `DEBUG` only).
   No Developer ID exists, so there is no team-id requirement to check.
6. **Re-check under root.** `HelperUpdateFlow.start` guards a single install with
   `HelperInstallState.begin()` and reads the version from the installed app's `Info.plist`.
   An unreadable or empty version aborts right there ("Не удалось прочитать версию
   установленного приложения") — degrading to `"0.0.0"` would make every release look newer and
   let root install on no basis. Then `ReleaseChecker` runs the daemon's own query, the client
   gets `nil` (= started) immediately, and only then `PackageDownloader` downloads: it requires
   `ReleasePackageURL.isTrusted`, stores into `/var/db/weto/updates` (dir 0700, pkg 0600 — never
   `/tmp`, where the package could be swapped between download and install) and `PackageInstaller`
   runs `/usr/sbin/installer -pkg … -target /`; the package is deleted regardless of outcome.
7. **Progress comes back by polling.** Because the reply was sent before the download, both the
   progress and a failure have to be read separately. The daemon keeps phase, fraction and
   failure text in `HelperInstallState`; the app polls `installState` every 0.4 s while the
   install is in flight and renders the phase in the dialog and in the popup banner. The
   fraction is real while downloading and honestly indeterminate during `installer`, which
   reports nothing. Silence from the daemon changes nothing (it is neither success nor failure),
   and an unknown phase code reads as "installing" so an older daemon cannot look finished.
8. **The installer removes both callers.** The new package's `preinstall` does
   `launchctl bootout system/com.weto.helper` and `killall WetoMenuBar` — the daemon kills
   itself and the app in the middle of its own install, which is why the progress normally never
   reaches a success state. `postinstall` bootstraps both again, and the app's launch agent has
   `KeepAlive`, so launchd brings the app back — this is what makes silent auto-install viable.

Files: `macos/Packages/UpdateKit/Sources/UpdateKit/UpdateController.swift`, `HelperUpdateInstaller.swift`,
`macos/Packages/UpdateKit/Sources/UpdateKitCore/UpdatePolicy.swift`, `UpdateProgress.swift`,
`UpdateDialogModel.swift`, `ReleasePackageURL.swift`,
`macos/Packages/UpdateKit/Sources/UpdateKitUI/UpdateWindowPresenter.swift`, `UpdateDialogView.swift`,
`macos/Packages/UpdateKit/Sources/UpdateKitXPC/`, `macos/Packages/UpdateKit/Sources/UpdateKitHelper/`,
`macos/Sources/WetoCore/WetoUpdate.swift`, `macos/Sources/WetoShared/WetoUpdateTheme.swift`,
`macos/Sources/WetoHelper/main.swift`, `macos/scripts/preinstall`, `macos/scripts/postinstall`.

The XPC surface of this flow is exactly `performUpdate`, `installState`, `uninstallHelper` —
every method has a caller, and only the read-only one was added for progress. The former
check-over-XPC branch (`checkForUpdate`, `checkForUpdateForced`, `getHelperVersion`) was removed:
it had no callers while being executed by a root process.

### Install and autostart: PKG → launchd → running copy

1. **Payload** (`macos/scripts/build.sh`): `Applications/Weto.app`,
   `Library/PrivilegedHelperTools/com.weto.helper`,
   `Library/LaunchDaemons/com.weto.helper.plist`. The user agent plist is *not* packaged.
   A component plist pins `BundleIsRelocatable=false`, and the build verifies it by expanding
   the component pkg — otherwise Installer would drop the app next to an older copy.
2. **`macos/scripts/preinstall`** (`set -u`, best effort): boots out `gui/<uid>/com.weto.app` for the
   console user, removes both `~/Library/LaunchAgents/com.weto.app.plist` and the legacy
   `/Library/LaunchAgents` one, boots out `system/com.weto.helper` (required before the binary
   is replaced), `killall WetoMenuBar`.
3. **`macos/scripts/postinstall`** (`set -euo pipefail` — every failure aborts the install loudly):
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

Files: `macos/scripts/build.sh`, `macos/scripts/preinstall`, `macos/scripts/postinstall`,
`macos/Resources/com.weto.helper.plist`, `macos/Sources/WetoMenuBar/WetoMenuBarApp.swift`,
`macos/Sources/WetoShared/LaunchAgentController.swift`, `macos/Sources/WetoShared/AppCoordinator.swift`.
