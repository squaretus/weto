# WetoShared (VM layer)

## Purpose
Everything between pure logic (`WetoCore`) and the UI (`WetoMenuBar`): the guard state
machine, process enforcement, observable stores for settings and journal, the update
view model and the two system-mutating helpers (launch agent, uninstall). All types are
`@MainActor`; the observable ones are `@Observable`. `WetoCore` decides *what* is true,
this layer decides *when* to ask and *what to do* with the answer.

## Key files
- `Sources/WetoShared/AppCoordinator.swift` — composition root, wired once in `WetoMenuBarApp`
- `Sources/WetoShared/GuardVM.swift` — observable facade for the UI, journal dedup, watchdog, tick loop
- `Sources/WetoShared/GuardController.swift` — decision state machine, owns the network probe
- `Sources/WetoShared/ProcessEnforcer.swift` — rule cache + single process scan per event
- `Sources/WetoShared/SettingsStore.swift` — `UserDefaults` + Keychain, guard-config change bus
- `Sources/WetoShared/EventLogStore.swift` — 10-entry ring buffer of `KillEvent`
- `Sources/WetoShared/LaunchAgentController.swift` — `~/Library/LaunchAgents/com.weto.app.plist`
- `Sources/WetoShared/Maintenance.swift` — `closeApp` and full `uninstall` plan
- `Sources/WetoShared/UpdateVM.swift`, `UpdateInstalling.swift` — release check + helper-driven install
- `Sources/WetoShared/StatusPresentation.swift`, `KillNotifying.swift`, `URLOpening.swift`
- Tests: `Tests/WetoSharedTests/` (`GuardVMTests` is the behavioural bulk, 31 KB)

## Entry points
- `AppCoordinator.init()` → wires real system adapters; `start()`, `stopForTermination()`
- `GuardVM.start()` / `stop()` / `handle(_ trigger: GuardTrigger)` / `awaitPendingProbe() async`
- `GuardVM.recheckNow()` — user-driven probe from the popup; `isProbing`, `lastReport` back it
- `GuardVM.refreshVPNCandidates()`, `refreshRunningTargets()`, `runningProcessCount(forTarget:)`,
  `displayName(forTarget:)`, `resolvedDescription(forTarget:)`, `unloadCompletely() → Result<Void, LaunchAgentError>`
- `SettingsStore` setters (`isEnabled`, `targets`, `vpnServiceID`, `blockedCountryCodes`,
  `blockedIPRangeTexts`, `pollIntervalSeconds`, `appTheme`),
  `setIPInfoToken(_) → Result<Void, SettingsPersistenceError>`,
  `addBlockedEntry(_) → Result<Void, BlacklistEntryError>`, `removeBlockedEntry(_)`,
  `migrateLegacyVPNSelection(in:)`, `onGuardConfigurationChange(_)`, `guardConfig`
- `EventLogStore.record(_)`, `clear()`
- `LaunchAgentManaging.enable() / disable() / bootout()`, `isInstalled`, `pointsAtCurrentBundle`
- `Maintenance.closeApp() → Result<Void, LaunchAgentError>`, `uninstall() → MaintenanceResult`
- `UpdateVM.startPeriodicCheck()`, `checkForUpdate()`, `primaryAction()`, `installUpdate()`,
  `openReleasePage()`, `stop()`, `availableUpdate`, `isInstallingUpdate`, `installFailure`;
  internal `refreshInstallOutcome()` — one poll of the daemon about a started install,
  internal so tests can step the loop by hand
- `UpdateInstalling.requestInstall(completion:)`, `requestLastFailure(completion:)`;
  `HelperUninstalling.uninstallHelper(completion:)`
- `StatusPresentation.title(for:)`, `lines(for:reading:)`, `lines(for:report:timeZone:)`,
  `detail(for:reading:)`

## Dependencies
- `WetoCore`: `GuardPolicy`, `VPNStatusResolver`, `ProcessMatcher`, `IPRange`, `ReleaseParser`, `Constants`
- `WetoSystem` protocols (injected, mocked in tests): `NetworkSnapshotReading`, `NetworkEventSourcing`,
  `GeoProbing`, `ProcessLocating`, `ProcessKilling`, `TargetResolving`, `SecretStoring`, `HTTPFetching`
- `WetoXPC`: `WetoXPCClient`, `UpdateService` (via `HelperUpdateInstaller`)
- Frameworks: `AppKit` (`NSWorkspace.open`, bundle paths), `UserNotifications`, `Observation`
- Storage: `UserDefaults(suiteName: "com.weto.shared")`, Keychain service `com.weto.ipinfo`,
  `~/Library/Caches/com.weto.app/`
- External processes: `/bin/launchctl`, `/bin/bash` (deferred bundle removal)

## Side effects
<!-- generated, verify -->
- Kills processes: `ProcessEnforcer.enforce` → `ProcessKilling.kill(pids:)`, driven from
  `GuardVM.apply(.kill)` and from the 250 ms watchdog while state is `.unsafe`.
- `UserDefaults` writes on every settings setter (write-through, no batching) and on every
  journal `record`/`clear`.
- Keychain write on `setIPInfoToken`; `Maintenance.uninstall` writes `nil` to the same account.
- Filesystem: writes/removes `~/Library/LaunchAgents/com.weto.app.plist`, removes the flag
  cache directory, spawns a detached `bash` that `rm -rf`s the `.app` after our pid exits.
- Spawns `launchctl bootout/bootstrap` for `gui/<uid>/com.weto.app`.
- Network: ipinfo + confirmation probes via `GeoProbing`; GitHub releases API every 6 h
  (`Constants.updateCheckInterval`), plus flag SVG prefetch on each new reading.
- XPC to `com.weto.helper` for install, for polling the outcome of a started install
  (`lastInstallFailure`, every `Constants.installOutcomePollSeconds` = 5 s while the spinner is
  up) and for helper self-uninstall.
- User notifications on each newly recorded kill; authorization requested in `start()`.
- Long-lived `Task`s: tick loop (`pollIntervalSeconds`, default 5 s), watchdog (0.25 s),
  probe task (300 ms debounce), update periodic task, install-outcome watch task (5 s, only
  between `.started` and either a reported failure or process death).
  All stored and cancelled — see invariants.

## Invariants / assumptions
<!-- generated, verify -->
- **A manual recheck must not cost the user their targets.** `GuardController.probeNow()`
  skips the debounce window *and* leaves `freshVerdict` alone, so pressing the button on a
  healthy VPN keeps the current `.safe` state instead of dropping into `verificationPending`
  (which would terminate everything before the request even left). Its answer is applied the
  normal way, so a recovered ipinfo lifts the block without waiting for the next tick.
- **One request per press.** `GuardVM.recheckNow()` refuses to start while `isProbing`:
  `free.freeipapi.com` allows 60 requests/minute and the poll loop already spends 12.
- **The launchd copy *is* the `com.weto.app` job.** launchd puts `XPC_SERVICE_NAME=com.weto.app`
  into the environment of the copy it started (a copy launched via `open` gets a long
  `application.com.weto.app.…` instead). `LaunchAgentController.isRunningAsAgent` reads exactly
  that. Any `launchctl bootout` of our own job from such a process is a SIGTERM to ourselves —
  the app vanished with no crash report, and re-registration produced endless respawn
  (`runs` in the hundreds) because the fresh copy died on the singleton port.
  Therefore, when `isRunningAsAgent`:
  `enable()` only writes the plist and returns (no `bootout`, no `bootstrap`),
  `disable()` only removes the plist (launchd releases the loaded job at logout),
  and `bootout()` stays the exclusive tool of `Maintenance.closeApp`, which *intends* to end
  the process. This must not be "simplified" back into one code path.
- Related UI-side rule: launch-at-login side effects hang off the `Binding` setter, never off
  `onChange` of state that `onAppear` synchronizes — otherwise the sync itself looked like a tap.
- Exactly one launch-agent file, `LaunchAgentController.defaultPlistPath`. `postinstall`, the
  settings toggle and the uninstaller must all address that same path; `/Library/LaunchAgents`
  is legacy only.
- Verdict freshness = `(config revision, snapshot fingerprint)`. Without the pair, every routine
  5 s tick re-entered `verificationPending` and killed targets over a perfectly healthy VPN.
- A stale probe never returns `safe`: `applyLatestNetworkOutcome` bails unless
  `revision == expected`, and re-reads settings + snapshot immediately before deciding.
- `GuardController` subscribes to config changes in `init`, not in `start()` — a setting changed
  before the guard starts must still shape the first decision.
- One process scan per event: `GuardVM.handle` stores `currentScan` and `enforce` reuses it;
  argv is only read when a `.script` rule exists.
- Rule cache is keyed on the raw `settings.targets` array; resolution touches the filesystem and
  LaunchServices, so it must not run per UI row (`runningProcessCount` reads the prepared list).
- Journal dedup is by pid **and** by reason within an episode; both sets are cleared only on `safe`.
- Boundary calls return `Result<Void, Error>`, never `Bool`: a silent Keychain or `launchctl`
  failure used to be reported as success.
- `SettingsStore.migrateLegacyVPNSelection` runs before the first decision and refuses to guess:
  an ambiguous or unqualified legacy name clears the selection and leaves the guard fail-closed.
- `UpdateVM` takes the current version as a parameter — under `swift test` / `swift run`
  `Bundle.main` is a foreign bundle.
- Release URLs are opened only when `https` + host `github.com`; the helper never receives a URL
  or version from us.
- **A release with no `.pkg` asset never reaches the daemon.** `ReleaseParser` leaves
  `downloadURL` empty in that case; `installUpdate` bails before `requestInstall`, sets
  `installFailure` and opens the release page instead of promising a one-click install
  (pinned by `test_release_without_a_package_does_not_ask_the_daemon`).
- **The spinner is cleared by polling, not by a reply.** `requestInstall` answers `.started`
  before the download begins, so `startWatchingInstall` asks `requestLastFailure` every 5 s;
  only a non-`nil` failure stops the spinner. A `nil` answer means "nothing to report" (which is
  also what a dead daemon looks like), never "failed"
  (`test_failure_after_the_start_reply_stops_the_spinner`).
- Every periodic task is stored so it can be cancelled: the update loop previously outlived
  everything because nobody held its handle. `installWatchTask` follows the same rule — it is
  cancelled in `stop()`, in `deinit` and as soon as a failure is shown.

## Failure hotspots
<!-- generated, verify -->
- `LaunchAgentController.enable/disable` — the self-bootout trap above; cost the project two
  releases. Any change here needs `LaunchAgentControllerTests` (`…does_not_boot_out_the_job_the_app_itself_is`).
- `GuardController.beginNetworkVerification` / `applyLatestNetworkOutcome` — revision bookkeeping;
  errors here show up as either kills on a healthy VPN or a stale `safe` after the VPN dropped.
- `GuardVM.enforce` journal dedup — the classic regression is `verificationPending` swallowing the
  real reason, or a relaunch an hour later leaving no trace.
- Task lifecycles (`tickTask`, `watchdogTask`, `probeTask`, `periodicTask`, `installWatchTask`):
  leaked loops keep killing after `stop()`; over-eager cancellation silently disables the
  watchdog or the install-outcome poll (the latter's symptom is an eternal install spinner).
- `UpdateVM.installUpdate` / `refreshInstallOutcome` — the install spinner has no success path by
  design: a successful install kills the app. Every *other* way out has to be explicit (daemon
  error, missing daemon, empty `downloadURL`, recorded late failure); a missing branch shows up
  as a spinner that never stops.
- `Maintenance.uninstall` step order — the agent must be unloaded before its plist is removed, and
  `awaitHelperUninstall` hard-caps at 5 s so a missing daemon cannot hang the uninstall.
- `Maintenance.scheduleBundleRemoval` builds a shell string; the path is quote-escaped, and it
  must stay that way.
- `SettingsStore` setters fan out to `emit(...)` synchronously on the main actor — a handler that
  mutates settings again would recurse.

## Related docs
- `.claude/rules/ARCHITECTURE.md` — key contracts (policy order, fail-closed, autostart)
- `docs/design-system.md` — for the UI that consumes `StatusPresentation`
