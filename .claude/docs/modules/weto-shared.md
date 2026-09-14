# WetoShared (VM layer)

## Purpose
Everything between pure logic (`WetoCore`) and the UI (`WetoMenuBar`): the guard state
machine, process enforcement, observable stores for settings and journal, the update
view model and the two system-mutating helpers (launch agent, uninstall). All types are
`@MainActor`; the observable ones are `@Observable`. `WetoCore` decides *what* is true,
this layer decides *when* to ask and *what to do* with the answer.

## Key files
- `macos/Sources/WetoShared/AppCoordinator.swift` — composition root, wired once in `WetoMenuBarApp`
- `macos/Sources/WetoShared/GuardVM.swift` — observable facade for the UI, journal dedup, watchdog, tick loop.
  Owns the pause side: `pausedProcesses` (popup badges), `pauseDeadline`, `pauseTargets()`/`settleResume()`,
  which call `ProcessEnforcer.pause`/`.resume` and record/refine the `kind: .paused` episode.
  `settleResume()` runs on every pass with running targets while the ledger is non-empty
  (the `.resume` effect is not a one-shot): the obligation is discharged by observation, so
  the episode is refined «возобновлено» only once the process was seen running again, and
  «не возобновлено: …» when SIGCONT did not stick (background job) or was refused. An entry that
  answered with a stop `Constants.resumeRetryLimit` times stops being poked (zsh's `notify` would
  print `suspended (tty input)` to the user once a second) — it stays on the books, and
  `terminate`/`stop` still signal it. `stop()` cannot observe anything after its own SIGCONT,
  so its outcome is «не подтверждено: … weto проверит их при следующем запуске» — neither the
  optimistic nor the pessimistic lie. `confirmResumed()` is the one exception to that promise and
  belongs to uninstall alone: there is no next launch to keep it, so the obligation is discharged by
  observation instead (see invariants). Both it and `stop()` go through `resumeFromLedger()` with an
  empty `skipping`, so entries the tick gave up on get that last signal too. A pill whose target worked between episodes and was stopped
  again adopts the new moment — that standing did start now, and `pause` only reports as `fresh`
  what it actually signalled, so a target that never came back up keeps its original `since`,
  which is the truth about it. `PausedProcess.since` records when weto stopped that pid; the
  countdown the badge shows is not read from it but from the reducer's phase
  (`pauseDeadline` → `phase.pausedSince`), because the 60 s ceiling belongs to the episode, not to
  one target. Only `isBackgrounded` is inherited across episodes — that one was written by
  observation, not by the plan's guess.
- `macos/Sources/WetoShared/GuardController.swift` — owns the one live `GuardMachine` (the reducer
  lives in `WetoCore`, see `weto-core.md`) plus the network probe: turns triggers into
  `GuardInput`, applies it, and asks `GuardVM` to enact whatever `GuardEffect` came back
- `macos/Sources/WetoShared/ProcessEnforcer.swift` — rule cache + single process scan per event;
  `pause(_:)` builds a `PausePlan` (skips only pids the kernel shows stopped *and* the ledger
  knows) and sends `.stop` in `stopOrder`; everything it actually stopped comes back in `fresh`,
  including a revived ledger entry — per-episode dedup of journal records lives one layer up, in
  `GuardVM.pausedEpisodePIDs`. The shells it stopped come back too, in `freshShells`, already
  shaped as `MatchedProcess(matchedBy: .shell)` with the name of the target whose terminal they
  hold (`PausePlan.shellTargets`): every SIGSTOP weto sends must be explainable from the kill
  journal alone, so `GuardVM.pauseTargets` journals `fresh + freshShells` into one episode. `resume(observing:skipping:)` sends `.resume` in the reverse of what
  the ledger holds (minus the entries that stopped being poked) and
  returns a `ResumeOutcome` (`released` / `unresolved`), `resumeOrphans()`
  is the crash-recovery path (only pids that are still stopped *and* still the same executable get
  `SIGCONT` — pid reuse must not resume a stranger). It reverses the ledger too: the file keeps
  entries in the order they were added, and `pause` adds them in the order the SIGSTOPs went out,
  so the real stop order survives into the next launch and the resume is its exact reverse.
  Reconstructing it from `isShell` ("non-shells, then shells") was an approximation that swapped a
  target and its own child. `resumeOrphans` also returns the walk it made
  (`(outcome:, observed:)`), and `GuardVM.surfaceRecovered` names the standing targets from that
  scan rather than walking every process a second time. Neither one clears the ledger: an entry is
  struck off only when the process is gone or the kernel showed it running, so a target that
  falls back to `T` via `SIGTTIN` keeps its entry and gets SIGCONT again next pass.
  `release(guarded:observing:)` is the third caller of that same settle: a live ledger entry that
  matches nothing in the current scan lost its only reason to stand — the user removed its rule —
  and it gets `SIGCONT` on that very pass instead of waiting for the episode's outcome, i.e. up to
  the 60 s ceiling after the user said «this is no longer mine». A shell is the exception, for the
  same reason it joins the plan at all: it is released only when no non-shell entry is still
  guarded, otherwise it takes the terminal back and its target lands on `SIGTTIN`. Signals go in
  the same reverse stop order, and the obligation is still discharged by observation —
  `freed` is who got the signal, `released` is who was observed and left the ledger
- `macos/Sources/WetoShared/StoppedLedger.swift` — `StoppedProcess` (pid + path + `isShell`),
  `StoppedLedgerPersisting` (`StoppedFile` at `stopped.json`, atomic temp+rename, next to the
  journals; `InMemoryStoppedLedger` for tests), `StoppedLedgerReadout` (`.entries`/`.corrupted` —
  a corrupted file reads as empty but is distinguishable at the boundary, so a broken ledger and
  an empty one don't silently mean the same thing to `startupRecovery`)
- `macos/Sources/WetoShared/GuardNotifying.swift` — `UserNotificationGuardNotifier`: two distinct
  notifications, `notifyTerminated` (existing) and `notifyBackgrounded` (a paused terminal target
  lost its foreground job — the process just "disappears" from its terminal without one).
  `onOpen` is the tap handler that opens the popup; `presentationWhileActive` makes notifications
  show even while weto's own window has focus, which is exactly when the user is watching status
  and needs the explanation
- `macos/Sources/WetoShared/PopupPresenting.swift` — the one-method boundary `MenuBarPopupPresenter`
  needs to open the popup from a notification tap, without pulling `WetoMenuBar` into this module
- `macos/Sources/WetoShared/SettingsStore.swift` — `UserDefaults` + Keychain, guard-config change bus
- `macos/Sources/WetoShared/EventLogStore.swift` — 100-entry ring buffer of `KillEvent`, one per killed process
- `macos/Sources/WetoShared/CheckLogStore.swift` — 50-entry ring buffer of `CheckEvent` (the second
  journal: every connectivity-check attempt, not just the ones that killed something).
  `CheckEvent.isWorthRecording` is the filter — see invariants
- `macos/Sources/WetoShared/JournalFile.swift` — `~/Library/Application Support/weto/journal.json`, temp + rename
- `macos/Sources/WetoShared/JournalExporter.swift` — the export envelope handed to a human or an agent
- `macos/Sources/WetoShared/LaunchAgentController.swift` — `~/Library/LaunchAgents/com.weto.app.plist`
- `macos/Sources/WetoShared/Maintenance.swift` — `closeApp` and full `uninstall` plan.
  The bundle, the daemon's files, `/var/db/weto` and the package receipt are root-owned and
  removed by the daemon from paths in `UpdateFeedConfiguration`; the app used to `rm -rf` its
  own bundle, hit permissions and reported success anyway, so it stayed in `/Applications`.
  Uninstall now **verifies** the bundle is gone instead of assuming it. Parity with
  `Resources/uninstall-weto.sh` is machine-checked — `scripts/tests/uninstall-parity-contract.sh`
- `macos/Sources/WetoShared/WetoUpdateTheme.swift` — weto skin for the `UpdateKit` dialog
- `macos/Sources/WetoCore/WetoUpdate.swift` — the update configuration this module wires up
- `macos/Sources/WetoShared/StatusPresentation.swift`, `URLOpening.swift`
- Tests: `macos/Tests/WetoSharedTests/` (`GuardVMTests` is the behavioural bulk); `StoppedLedgerTests`,
  `GuardNotifyingTests`, `CheckLogStoreTests` cover the additions above

## Entry points
- `AppCoordinator.init()` → wires real system adapters; `start()`, `stopForTermination()`,
  `confirmResumed() → [StoppedProcess]`
- `GuardVM.start()` / `stop()` / `handle(_ trigger: GuardTrigger)` / `awaitPendingProbe() async`
- `GuardVM.confirmResumed() → [StoppedProcess]` — re-sends `SIGCONT` to what the ledger still holds
  and returns whoever the scan still shows standing. Called after `stop()`, by uninstall only
- `GuardVM.recheckNow()` — user-driven probe from the popup; `isProbing`, `lastReport` back it
- `GuardVM.refreshVPNCandidates()`, `refreshRunningTargets()`, `runningProcessCount(forTarget:)`,
  `displayName(forTarget:)`, `resolvedDescription(forTarget:)`, `unloadCompletely() → Result<Void, LaunchAgentError>`
- `SettingsStore` setters (`isEnabled`, `targets`, `vpnAppRule`, `blockedCountryCodes`,
  `blockedIPRangeTexts`, `allowedCountryCodes`, `allowedIPRangeTexts`, `appTheme`),
  `setIPInfoToken(_) → Result<Void, SettingsPersistenceError>`,
  `addEntry(_:to: GeoListKind) → Result<Void, GeoListEntryError>`, `removeEntry(_:from:)`,
  `entries(of:)` — one path for both geo lists; the `…Blocked…` / `…Allowed…` trio of each list is a
  delegating wrapper kept for UI bindings,
  `migrateLegacyVPNSelection(in:)`, `onGuardConfigurationChange(_)`, `guardConfig`
- `EventLogStore.record(_ batch: [KillEvent])`, `refine(episodeID:reasonText:resolutionText:…)`, `clear()`
- `JournalExporter.make(settings:events:at:osVersion:) → JournalExport`; `JournalExport.encoded()`,
  `JournalExport.fileName(at:)`
- `LaunchAgentManaging.enable() / disable() / bootout()`, `isInstalled`, `pointsAtCurrentBundle`
- `Maintenance.closeApp() → Result<Void, LaunchAgentError>`, `uninstall() → MaintenanceResult`
- `AppCoordinator.update` — an `UpdateController` from `macos/Packages/UpdateKit`, built from
  `WetoUpdate.configuration`; `AppCoordinator.updateWindow` owns the dialog presenter.
  The mechanism itself is documented in `modules/update-kit.md`
- `WetoUpdateTheme.make(for:) → UpdateTheme` — the only weto-specific part of the dialog
- `UpdateInstalling.requestInstall(completion:)`, `requestLastFailure(completion:)`;
  `HelperUninstalling.uninstallHelper(completion:)`
- `StatusPresentation.explanation(for:remainingPause:) → StatusExplanation` — the three popup
  lines (what weto did / why / what's next); `shouldExplain(_:)` gates them off for `.disabled`
  and `.protected`, where there is nothing to explain
- `StatusPresentation.lines(for:reading:)`, `lines(for:report:timeZone:)`, `detail(for:reading:)`
- `GuardVM.showTerminal(for pid:) → Bool` — the popup's "Показать терминал" button, delegates to
  `TerminalLocating`
- `StoppedLedger.add(_:)`/`.remove(_:)`/`.clear()`, `.pids`, `.startedFromCorruptedFile`
- `CheckLogStore.record(_:)` (drops anything `!isWorthRecording`), `.all`, `.clear()`
- `GuardNotifying.notifyTerminated(reasonText:killedCount:)`, `.notifyBackgrounded(targetName:)`;
  `UserNotificationGuardNotifier.activate()`, `.onOpen` (tap → open popup)

## Dependencies
- `WetoCore`: `GuardPolicy`, `ProcessMatcher`, `IPRange`, `ReleaseParser`, `Constants`
- `WetoSystem` protocols (injected, mocked in tests): `NetworkSnapshotReading`, `NetworkEventSourcing`,
  `GeoProbing`, `ProcessLocating`, `ProcessSignaling` (was `ProcessKilling`), `TerminalLocating`,
  `TargetResolving`, `SecretStoring`, `HTTPFetching`
- `StoppedLedgerPersisting` (injected, mocked in tests as `InMemoryStoppedLedger`)
- `UpdateKit` / `UpdateKitUI`: `UpdateController`, `HelperUpdateInstaller`, `UserDefaultsUpdateStore`,
  `UpdateWindowPresenter` (see `modules/update-kit.md`)
- Frameworks: `AppKit` (`NSWorkspace.open`, bundle paths), `UserNotifications`, `Observation`
- Storage: `UserDefaults(suiteName: "com.weto.shared")`, Keychain service `com.weto.ipinfo`,
  `~/Library/Caches/com.weto.app/`
- External processes: `/bin/launchctl`, `/bin/bash` (deferred bundle removal)

## Side effects
<!-- generated, verify -->
- Signals processes: `ProcessEnforcer.pause(_:)` → `ProcessSignaling.send(.stop, …)` in
  `PausePlan.stopOrder`; `.terminate(_:)` → `.send(.kill, …)` for matched pids and `.send(.resume, …)`
  for anyone in the stopped ledger that no longer matches (a rule change or the shell of a target
  under `.danger` — leaving it stopped would freeze it until the next weto launch); `.resume(observing:)` →
  `.send(.resume, …)` over every live ledger entry, reversed. Driven from `GuardVM.applyCurrentAction`
  (`phase.action`: `.pause`/`.terminate`) and from the 250 ms watchdog while paused or unsafe;
  the resume side is driven by `GuardVM.settleResume()` from `apply`'s `.run` branch and from
  every `handle(_:)` (a newsless tick never reaches `apply` — `GuardController.emit` swallows it).
  `.release(guarded:observing:)` → `.send(.resume, …)` for ledger entries the guard no longer
  holds, driven from `GuardVM.pauseTargets` (watchdog) and from `handle(_:)` while `phase.action`
  is `.pause`, once per pass (`releasedPass`). The record gets its own outcome —
  «не подтверждено: цель снята с охраны …» when the signal went out, «продолжен: цель снята
  с охраны» once observed — and the episode-wide refine leaves it alone
  (`EventLogStore.refine(skipping:)`), because its standing ended earlier and for another reason.
- Writes `stopped.json` on every ledger `add`/`remove`/`clear` — atomic temp+rename, same pattern
  as the journals. `add` dedupes by the same identity the rest of the code uses — pid **and**
  path — and an entry whose pid matches but whose path differs is provably dead (one pid, one live
  process), so the fresh record replaces it and goes to the tail: the ledger holds the stop order,
  and the replacement was stopped now. Deduping by pid alone silently dropped the fresh record, and
  the next pass struck the stale one off as recycled — without `SIGCONT`, leaving the target frozen
  with nothing on the books to thaw it.
- `UserDefaults` writes on every settings setter (write-through, no batching) and on every
  journal `record`/`clear`.
- Keychain write on `setIPInfoToken`; `Maintenance.uninstall` writes `nil` to the same account.
- Filesystem: writes/removes `~/Library/LaunchAgents/com.weto.app.plist`, removes the flag
  cache directory, spawns a detached `bash` that `rm -rf`s the `.app` after our pid exits.
- Spawns `launchctl bootout/bootstrap` for `gui/<uid>/com.weto.app`.
- Network: ipinfo + confirmation probes via `GeoProbing`; GitHub releases API every hour
  (`UpdateFeedConfiguration.checkInterval`). Flags come from the bundle, so no network there.
- XPC to `com.weto.helper` for install, for polling the progress of a started install
  (`installState`, every 0.4 s while the install is in flight) and for helper self-uninstall.
- User notifications on each newly recorded kill; authorization requested in `start()`.
- Long-lived `Task`s: tick loop (1 s), geo schedule (5 s), watchdog (0.25 s),
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
- **A manual recheck always goes to the network.** Local grounds (VPN down, no VPN chosen,
  guard off, no targets) decide the fate of the targets and are applied immediately, but they
  no longer short-circuit the request: the button answers "where am I right now", and that
  question does not depend on whether the guard needs a verdict. Before this, the popup went
  silent about the country exactly when the user pressed the button to see it.
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
  5 s tick re-entered `verificationPending` and killed targets over a perfectly healthy VPN. The
  fingerprint covers the traffic carrier and its local address, never the whole snapshot: with a
  machine-wide one, a second VPN living beside the working tunnel (a corporate client dropping and
  reconnecting on its own) invalidated the verdict and killed the targets, though the traffic never
  moved.
- The VPN app's rule never enters `Scan.rules`. `enforce` kills everything in that list, and killing
  the client would make the unsafe state irreversible; choosing an app also drops it from `targets`.
- A stale probe never returns `safe`: `applyLatestNetworkOutcome` bails unless
  `revision == expected`, and re-reads settings + snapshot immediately before deciding.
- `GuardController` subscribes to config changes in `init`, not in `start()` — a setting changed
  before the guard starts must still shape the first decision.
- **Both geo lists take the same code path, told apart only by `GeoListKind`.** Parsing (two letters
  → country code, otherwise `IPRange`), the duplicate refusal and removal exist once; a second copy
  for the whitelist would drift from the blacklist silently. `GeoListEntryError` (ex
  `BlacklistEntryError`) is shared for the same reason.
- **A whitelist edit invalidates the standing verdict** (`Field.whitelist` on both allowed-list
  setters): a tightened list must not keep targets alive on an answer obtained under the old one
  (`test_old_config_probe_result_is_ignored_after_whitelist_change`). Absent keys are read as `?? []`
  — an empty whitelist, which is what keeps older settings behaving exactly as before.
- One process scan per event: `GuardVM.handle` stores `currentScan` and `enforce` reuses it;
  argv is only read when a `.script` rule exists.
- Rule cache is keyed on the raw `settings.targets` array **and on time**
  (`Constants.targetRuleRefreshSeconds`, 2 s). The entries-only key silently rotted: a binary's
  symlink-resolved path usually carries the version (`…/claude/versions/2.1.228`), so every
  update of a target changed it, the cached rule kept pointing at the previous version, and the
  target dropped out of the running list *and* out of enforcement until it was re-added by hand.
  Resolution touches the filesystem and LaunchServices, so it must not run per UI row
  (`runningProcessCount` reads the prepared list) and must not run per watchdog scan —
  hence the window rather than resolving every time (`test_rules_are_not_resolved_again_within_the_refresh_window`).
- **Re-resolution never narrows the guard.** A refreshed rule keeps the launch paths it has
  seen before, so a session started on the previous binary — `proc_pidpath` still reports the
  old path — stays matched; a forgotten path no longer exists on disk, so no new process can
  claim it. A target that stops resolving (the instant its file is being replaced) keeps its
  last known rule instead of disappearing. Both are fail-closed by intent and pinned by
  `ProcessEnforcerTests`.
- **One record per killed process, one `episodeID` per pass.** A record used to describe the whole
  pass — "claude" plus thirty-four pids on one line — which answers neither "what exactly died" nor
  "why so many". Each record now carries its pid, parent, resolved path and a `matchedBy` basis:
  `rule` / `descendant` / `shell` — descendants are what explains dozens of kills for a single
  target, and `shell` is the process that matched nothing and was stopped only because it holds
  the target's terminal.
- Journal dedup is by the pair **reason + pid**; both that set and `recordedReasons` are cleared
  only on `safe`. The same process under the same reason writes nothing twice; a relaunched one
  always writes.
- **One episode, one set of entries: the reason is refined, not appended.** Fail-closed kills before
  the verdict exists, so the first thing written is `verificationPending` — "don't know yet". A
  second later the real reason is known, but on a live machine nothing gets killed again (the
  targets are already dead), so no second entry would ever appear and the journal kept the excuse
  instead of the cause. `GuardVM` remembers the episode id and `EventLogStore.refine` rewrites the
  reason, the geo readout and the diagnostics of **every** record in it; the reason key inside
  `recordedKills` is swapped along with the text, otherwise the refined reason counts as new and
  produces a duplicate set. Linux mirrors this through `KillReporting.refine` — see `linux-guard`.
- **An episode that ends `safe` records how it ended.** The verdict goes stale, fail-closed kills,
  and a second later the probe answers "all good". There is no reason to refine — it really was
  "not verified yet" — but without `resolutionText` the record keeps that excuse forever and the
  kill reads as random. This is the single most common complaint the journal exists to answer.
- **Diagnostics never reach the screen.** `KillDiagnostics` — staleness breakdown, outgoing
  interface and address, VPN app status, per-service traces with raw bodies — lives in the record
  and in the export only. The popup and the settings journal show target, reason and geo readout,
  exactly as before.
- The journal lives in a file, not in the settings plist: the plist is read whole on every launch,
  and raw service bodies would make that hundreds of kilobytes. History migrates once out of the
  old `eventLog` key, which is then removed; migration never overwrites an existing file, or
  "clear journal" would resurrect what was cleared.
- Boundary calls return `Result<Void, Error>`, never `Bool`: a silent Keychain or `launchctl`
  failure used to be reported as success.
- `SettingsStore.migrateLegacyVPNSelection` runs before the first decision and refuses to guess:
  an ambiguous or unqualified legacy name clears the selection and leaves the guard fail-closed.
- `UpdateController` takes the current version as a parameter — under `swift test` / `swift run`
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

- **Request thrift applies to the verdict, not to the screen.** `GuardController.evaluate`
  refreshes the geo readout even when a local reason already settled the targets' fate:
  one probe per change of the (revision + network fingerprint) pair, and only while the
  guard is armed (enabled and with targets). While the thrift covered the readout too, the
  popup kept the fallen tunnel's address and country forever — it displayed protection that
  no longer existed. A stale readout is cleared before the network answers (`onReport(nil)`,
  which also clears `lastReading`, since the popup falls back to it): a dash is more honest
  than someone else's country. Such a probe never softens the verdict.

- **A pause episode's staleness is captured once, at open, and survives resolution.**
  `pauseTargets()` reads `controller.lastStaleness` into `pauseStaleness` only when
  `pauseEpisodeID` is still `nil` (the episode is new); `resolvePauseEpisode` reuses that same
  stored value for the `.refine` call, never re-asking the controller — outside `.paused` the
  controller answers `nil`, and a safe resume would otherwise silently erase the freshness
  diagnosis from an already-written record (`GuardVMTests.test_a_bad_result_on_a_cold_start_pauses…`
  asserts it survives).
- **The stopped ledger is the only thing standing between a weto crash and a target frozen
  forever.** `GuardVM.start()` calls `enforcer.resumeOrphans()` once, before the event source and
  the tick loop start. A clean or absent `stopped.json` needs no journal entry — an empty read is a
  legitimate "nothing to resume" — but a *corrupted* file writes `CheckEvent(trigger:
  .startupRecovery, outcome: .ledgerUnreadable)`: the obligation ("SIGCONT whoever we stopped last
  time") went unfulfilled, and the check-journal is the only record of it, since the kill-journal
  only ever hears about processes actually terminated. `resumeOrphans` never trusts a bare pid: an
  entry only resumes if the live process at that pid is still stopped *and* still the same
  `executablePath` — pid reuse must not `SIGCONT` a stranger. And it never forgets an entry it did
  not resolve: sending SIGCONT is not resuming (`kill` returns 0 for a background job that
  immediately takes `SIGTTIN` and stops again), so a still-stopped entry stays on the books and
  the tick loop keeps signalling it — that is the bug that left three of the owner's processes
  in state `T` for hours with an empty `stopped.json`. An entry that survives that recovery is
  made visible in the same call, off the walk `resumeOrphans` already made:
  `GuardVM.surfaceRecovered` seeds `pausedProcesses` from it (badge, `fg` hint and «Показать
  терминал»), opens a kill-journal episode of its own for everything still standing
  (`GuardVM.recordRecoveryEpisode`: `kind: paused`, reason «найдены остановленными от прошлого
  запуска weto…», date from the ledger, `matchedBy: .shell` for a shell entry, resolution appended
  by the same `resolvePauseEpisode`) and writes one `CheckEvent(trigger: .startupRecovery,
  outcome: .standingProcessesRemain)` per recovery, not per tick. Both journals are needed: the
  checks one answers "what did weto do at startup", the kill journal "why was this process
  standing" — and the ledger cannot answer the latter, it drops an entry the moment the process
  is observed running.
- **Uninstall is the only exit where the obligation cannot be handed on, so it is observed.**
  Every other exit leaves `stopped.json` on disk for `resumeOrphans` to read next launch;
  uninstall deletes the ledger together with the app, and a process that never came back up from
  the last `SIGCONT` would stay frozen with nobody left to thaw it. `GuardVM.confirmResumed()`
  therefore re-signals and re-reads the scan, and the caller (`MaintenanceCard`) repeats it up to
  six times 300 ms apart before naming the survivors to the user. It deliberately does **not**
  refine the episode a second time: `stop()`'s «не подтверждено» is the journal's record of that
  standing, and a second write would turn it into a different answer about the same event.
- **Two notifications, two purposes, one delegate.** `notifyTerminated` is the pre-existing "your
  targets died" banner; `notifyBackgrounded` exists because a paused terminal target that loses its
  foreground job otherwise just vanishes from its terminal with no explanation — the notification
  is the only place the user learns `fg` will bring it back. Both must show even while weto's own
  window has focus (`presentationWhileActive`), because "the popup is open" is exactly when the
  user is looking for the explanation, not when they've stopped caring.
- **Not every check is worth a journal entry.** `CheckEvent.isWorthRecording`: a button press, a
  path change, a settings edit or the crash-recovery check always write; the 5 s geo schedule
  writes only a *failed* request — a successful routine tick says nothing new, and recording every
  scheduled attempt would evict the one entry the check-journal exists for (the real failure) from
  its 50-slot ring within about four minutes.

## Failure hotspots
<!-- generated, verify -->
- `LaunchAgentController.enable/disable` — the self-bootout trap above; cost the project two
  releases. Any change here needs `LaunchAgentControllerTests` (`…does_not_boot_out_the_job_the_app_itself_is`).
- `GuardController.evaluate` / `applyLatestNetworkOutcome` — revision bookkeeping; errors here show
  up as either kills on a healthy VPN or a stale `safe` after the VPN dropped. Since the pause
  model landed, a lost verdict routes through `GuardMachine.apply(.verdictLost)` — a wrong branch
  there shows up as targets pausing when they should keep running, or the reverse.
- `GuardVM.applyCurrentAction` journal dedup (`pauseTargets`/`terminateTargets`) — the classic
  regression is a stale reason swallowing the real one, a relaunch leaving no trace, or a pause
  episode's `diagnostics.staleness` getting recomputed at resolution instead of reused from the
  moment the episode opened (`resolvePauseEpisode` must reuse `pauseStaleness`, not call
  `controller.lastStaleness` again — the latter is `nil` outside `.paused`).
- Task lifecycles (`tickTask`, `watchdogTask`, `probeTask`, `periodicTask`):
  leaked loops keep killing after `stop()`; over-eager cancellation silently disables the
  watchdog or the install-outcome poll (the latter's symptom is an eternal install spinner).
- The install progress has no success path by design: a successful install kills the app. Every
  *other* way out has to be explicit (daemon error, missing daemon, empty `downloadURL`, reported
  failure phase); a missing branch shows up as progress that never stops. Lives in
  `UpdateController` now — see `modules/update-kit.md`.
- `Maintenance.uninstall` step order — the agent must be unloaded before its plist is removed, and
  `awaitHelperUninstall` hard-caps at 5 s so a missing daemon cannot hang the uninstall.
- `Maintenance.scheduleBundleRemoval` builds a shell string; the path is quote-escaped, and it
  must stay that way.
- `SettingsStore` setters fan out to `emit(...)` synchronously on the main actor — a handler that
  mutates settings again would recurse.

## Related docs
- `.claude/rules/ARCHITECTURE.md` — key contracts (policy order, fail-closed, autostart, pause)
- `features/geo-whitelist.md` — the allowed-exits list this store persists
- `features/pause-instead-of-kill.md` — pause/resume path end to end
- `decisions/pause-instead-of-kill.md` — why unproven pauses instead of killing
- `docs/design-system.md` — for the UI that consumes `StatusPresentation`, the pause badge and
  the "Показать терминал" affordance
