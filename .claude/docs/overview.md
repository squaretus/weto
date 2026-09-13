# System Overview

## Data Flows

### Guard cycle: verdict, pause and resume

`GuardPolicy.decide` answers `safe` / `unproven(reason)` / `kill(evidence)`; only `kill` is
positive proof of a leak. Everything else runs through the pure reducer `GuardMachine`, which
turns a decision into one of six phases and either keeps targets running, pauses them
(`SIGSTOP`, with a 60 s ceiling), or terminates them. There is no state left that kills on
"no verdict yet" — that case runs the targets and waits for an answer.

1. **Trigger.** `macos/Sources/WetoSystem/NetworkEventSource.swift` emits `.networkPath`
   (`NWPathMonitor`), `.dynamicStore` (`SCDynamicStore` keys: global IPv4, per-service IPv4,
   interface link), `.route` (a `PF_ROUTE` socket, coalesced — bringing up a tunnel adds routes
   by the hundred), `.wake`, `.appLaunched(bundleID:)` and `.appTerminated(bundleID:)`
   (`NSWorkspace`, GUI apps only). Independently `GuardVM.startTicking` emits `.tick` every
   second and `startGeoTicking` emits `.geoSchedule` every 5 s — the only trigger that goes to
   the network on its own. `SettingsStore.emit` → `GuardController.configurationChanged` bumps
   `revision`, drops the established verdict and calls `evaluate()` directly — a settings edit
   is recomputed from the reading already in hand, without a probe.
2. **One process scan per trigger.** `GuardVM.handle` calls `ProcessEnforcer.scan(includingVPNApp:)`
   once, stores it in `currentScan` and publishes `runningTargets` for the UI. argv is read
   (`KERN_PROCARGS2`) only when at least one rule is `.script`. Rules are resolved
   (filesystem + LaunchServices) only when `settings.targets` changed. `.appLaunched`
   short-circuits: non-target bundle IDs return immediately, and if the phase's action is
   already `.pause` or `.terminate`, `applyCurrentAction()` acts on the new pid at once rather
   than waiting for the next tick. `.geoSchedule` skips the verdict path entirely and only asks
   the network.
3. **Local decision first.** `GuardController.evaluate` reads `settings.guardConfig` and
   `snapshotReader.snapshot()`, asks `vpnAppStatus()` (the same scan, matched against the chosen
   app's rule), then `GuardPolicy.decideLocal`. A local `.kill` (the chosen VPN app closed) feeds
   `GuardMachine.apply(.evidence(evidence))` directly, bypassing the probe — a closed VPN client
   needs no network call to be noticed, and `didTerminateApplicationNotification` makes it
   instant.
4. **No verdict for this path keeps targets running.** With no local answer and no established
   verdict for the current fingerprint (cold start, path change, a lost verdict), `announceLoss`
   feeds `GuardMachine.apply(.verdictLost(cause))`, which moves the phase to `.verifying(cause)` —
   a *running* phase — and asks for a probe after the 300 ms debounce
   (`Constants.networkEventDebounceSeconds`). Nothing pauses or terminates before that probe
   answers: the accepted cost is a window of up to ~5 s with no verdict at all. Freshness is the
   pair «config revision + network snapshot fingerprint» (`NetworkSnapshot.verdictFingerprint`:
   the interface the kernel picks for the verdict request plus that interface's local address),
   not plain snapshot equality — the set of interfaces is deliberately absent, since a
   machine-wide fingerprint reads a second VPN reconnecting beside the working tunnel as a path
   change. Once the verdict is lost, `.verdictLost` does nothing further while paused or
   terminated — only a real probe answer moves those phases.
5. **Probe.** `GeoProbe.probe()`: Keychain token → ipinfo Lite (`v4.api.ipinfo.io`),
   `IPAddress.isValid` on the returned address *before* it goes into a URL, then confirmation
   from either interchangeable confirmer (`get.geojs.io`, `free.freeipapi.com` — a refusal puts
   that one on a 300 s cooldown and the other is asked), and that confirmation is served from the
   per-address cache while the 60 s soft ceiling holds. Address and primary country are never
   cached. When ipinfo refuses, the probe asks the geojs "who am I" endpoint instead: the address
   is what lets the guard decide whether the previous verdict may stand. The return value is a
   `GeoProbeReport` — per-source outcome, `NWPathMonitor` path flag, timestamp — and the guard
   verdict is derived from `report.outcome`, so the popup and the enforcement read the same
   object. A press of the popup's recheck button enters here through `GuardController.probeNow()`:
   no debounce, and freshness is deliberately *not* invalidated, so the press cannot pause or
   terminate targets on a healthy VPN. The press also bypasses the local short-circuit: even with
   the VPN down or the guard off, the request goes out — the local decision is applied first, then
   the report arrives and fills the popup. Without an ipinfo token the probe asks
   `get.geojs.io/v1/ip/country.json` about the caller and reports that country as the confirmation
   line; the guard verdict still requires ipinfo, so it stays fail-closed.
6. **Decide, then reduce.** `applyLatestNetworkOutcome` drops outcomes whose `revision` is stale,
   re-reads config and snapshot immediately before deciding (a slow probe must never resurrect
   `safe`), publishes the report (`GuardVM.receive` keeps `lastReport`) and calls
   `admissibleOutcome` to turn a silent ipinfo into something `GuardPolicy.decide` can read: the
   reference service naming the same address as the established verdict becomes
   `.degraded(previous:, detail:)` — an answer, not silence, so `decide` treats it like a resolved
   reading (targets keep running; the phase becomes `interference`, shield amber, evidence
   attached) — while a *different* address becomes `.addressChanged(observed:, previous:)`, which
   `decide` reports as `.unproven(.addressChanged)` with no tolerance: it pauses on this first
   probe like any other unproven answer. The decision (`safe` / `unproven(reason)` /
   `kill(evidence)`) becomes a `GuardInput` (`.verdict`, `.reassessment`, `.evidence`,
   `.verdictLost`, `.tick` or `.disarmed`) fed to `GuardMachine.apply(_:at:)` — a pure function,
   pinned by the shared golden fixture `shared/fixtures/guard-transitions.json` and run by both
   `GuardMachineTests` (Swift) and the Rust port (`linux-guard`). It returns one `GuardEffect`:
   `.none`/`.pause`/`.resume`/`.terminate`, and `GuardController` is the sole owner of the one
   live `GuardMachine`.
7. **Plan and signal a pause.** On `.pause`, `GuardVM.pauseTargets()` asks
   `ProcessEnforcer.pause(_:)`, which calls `PausePlanner.plan(matched:processes:)` (pure, in
   `WetoCore`) for a `PausePlan`: who to stop and in what order (a foreground job's shell before
   its target, parent before descendants), who is already stopped by the user — `Ctrl-Z` — before
   the guard ever touched it (skip, both ways), and whose target lost its terminal in the process
   (`backgrounded`). `ProcessSignaling.send(.stop, to: plan.stopOrder)` — the boundary in
   `WetoSystem` — then delivers signals strictly in that order; this is the only place
   `SIGSTOP`/`SIGCONT`/`SIGKILL` are actually sent. Every pid actually stopped is added to the
   `StoppedLedger` (`stopped.json`, next to the journals) *before* anything else, and the pause
   opens a `kind: .paused` journal episode (reason = the phase's `UnprovenReason`). A
   backgrounded terminal target also gets a `notifyBackgrounded` system notification, since it
   otherwise just "disappears" from its terminal with no explanation.
8. **Hold the action.** `GuardVM.apply` starts a 250 ms watchdog (`Constants.watchdogIntervalSeconds`)
   for both `.pause` and `.terminate` and cancels it on `.run`. While paused, the watchdog's
   `applyCurrentAction` re-runs `pauseTargets()` to sweep up newborn descendants; the probe keeps
   its normal rhythm regardless, and the countdown is `GuardVM.pauseDeadline`
   (`pausedSince + pauseCeilingSeconds`, 60 s), read by the popup's `WetoPauseBadge` and by
   `StatusPresentation.explanation`'s third line off the same `TimelineView` clock. Under
   `.terminate`, the same watchdog instead re-runs `terminateTargets(evidence)` — `ProcessMatcher.
   matches` (rule hit plus `ProcessTree` descendants, which inherit the root's target name) →
   `ProcessSignaling.send(.kill, …)`; `ESRCH` counts as terminated, other errno values surface as
   `permissionFailure` in the UI. This is the only way to catch terminal targets born after the
   phase changed: `NSWorkspace` reports GUI apps only.
9. **Resolve.** `GuardVM.settleResume()` — on every pass with running targets while the ledger is
   non-empty, not just the one carrying the `.resume` effect — calls
   `ProcessEnforcer.resume(observing:)`: `ProcessSignaling.send(.resume, …)` over every live entry,
   reversed. An entry is struck off only once the process is gone or the kernel showed it running:
   `kill(SIGCONT)` returns 0 for a background job that immediately takes `SIGTTIN` and stops again,
   so a target still in state `T` keeps its entry and is signalled again next tick — up to
   `Constants.resumeRetryLimit` answers, after which it keeps the entry but stops being poked
   (zsh's `notify` prints `suspended (tty input)` on every answer).
   `resolvePauseEpisode` refines the open episode with how it ended — «возобновлено» only for an
   observed resume, «не возобновлено: …» otherwise, and the popup keeps its badge with the `fg`
   hint instead of pretending the target came back. A `.terminate` effect
   instead kills whatever still matches the rules and resumes (never leaves stopped) anyone in the
   ledger that no longer does, so nothing is left frozen past the point where it stops being
   watched; reaching the pause ceiling with no answer resolves the same way, with
   `UnsafeEvidence.pauseExpired` as the evidence.
10. **Record.** `EventLogStore` (`journal.json`, 100-entry ring buffer) holds one `KillEvent` per
    process actually stopped or terminated, deduplicated by *both* pid and reason within an
    episode — a repeat reason with a new pid writes `.launchBlocked` rather than a fresh
    `.terminated`. `CheckLogStore` (`checks.json`, 50-entry ring buffer) is a second, independent
    journal for connectivity-check *attempts* (trigger + outcome), including probes that answered
    nothing. `UserNotificationKillNotifier` silently no-ops without a bundle id (`swift run`,
    tests).
11. **Recover from a crash.** `GuardVM.start()` calls `ProcessEnforcer.resumeOrphans()` once,
    before anything else starts: it `SIGCONT`s only pids that are still stopped *and* still the
    same executable (pid reuse must not resume a stranger), in the exact reverse of the order the
    ledger recorded — that file preserves the real stop order — and keeps every entry it did not
    resolve, leaving it to the tick loop above to observe and re-signal. Whatever survives that
    call is surfaced at once, off the same walk (`resumeOrphans` hands its scan back rather than
    have the caller repeat it) — `GuardVM.surfaceRecovered` seeds the popup's standing list (badge,
    `fg` hint, «Показать терминал») and writes one `CheckEvent(trigger: .startupRecovery,
    outcome: .standingProcessesRemain)`, one per recovery — because this launch has no pause
    episode and the kill-journal is silent about it by construction. A
    corrupted `stopped.json` is read as empty (never blocks startup) but writes one
    `CheckEvent(trigger: .startupRecovery, outcome: .ledgerUnreadable)` to the check-journal,
    since the kill-journal has no way to record an unmet obligation that killed nothing.

Files: `macos/Sources/WetoSystem/NetworkEventSource.swift`, `macos/Sources/WetoShared/GuardVM.swift`,
`macos/Sources/WetoShared/GuardController.swift`, `macos/Sources/WetoCore/GuardPolicy.swift`,
`macos/Sources/WetoCore/GuardMachine.swift`, `macos/Sources/WetoCore/PausePlan.swift`,
`macos/Sources/WetoCore/Model/NetworkSnapshot.swift`, `macos/Sources/WetoSystem/GeoProbe.swift`,
`macos/Sources/WetoShared/ProcessEnforcer.swift`, `macos/Sources/WetoCore/ProcessMatcher.swift`,
`macos/Sources/WetoSystem/ProcessSignaler.swift`, `macos/Sources/WetoShared/StoppedLedger.swift`,
`macos/Sources/WetoShared/GuardNotifying.swift`, `macos/Sources/WetoSystem/TerminalLocator.swift`,
`macos/Sources/WetoShared/EventLogStore.swift`, `macos/Sources/WetoShared/CheckLogStore.swift`,
`macos/Sources/WetoMenuBar/StatusPopupView.swift`.

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
