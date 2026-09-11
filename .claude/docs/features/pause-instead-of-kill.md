# Pause instead of kill on an unproven verdict

## Goal
Stop terminating targets on anything short of positive proof of a leak. Before this feature,
"no verdict yet" and "the geo services went silent" both ended in `SIGKILL` exactly like a
blacklisted address — a client crash-reconnecting on its own killed the user's work as often as
an actual leak did. Now only `UnsafeEvidence` (chosen VPN app not running, blacklisted address,
blocked country, country conflict, whitelist miss, or the pause ceiling expired) kills anything.
Everything else — no verdict for the current path, ipinfo silent, confirmation silent, a
different address named by the fallback — is `UnprovenReason` and pauses the targets
(`SIGSTOP`) with a 60 s ceiling instead. See `decisions/pause-instead-of-kill.md` for the full
argument and the owner's 2026-09-09 amendment (tolerance and a standing "Проверка" were both
tried and then removed — see below).

## Scope
Both platforms behave the same way. On Linux the screen has not caught up yet: the pill per
standing target, the countdown and the `fg` hint are not drawn, and the status titles are the
interim ones — everything the screen needs is already in `GuardSnapshot` (`phase`, `paused`,
`pause_deadline`). See `modules/linux-guard.md`.

Linux files: `weto-core/src/guard_machine.rs` and `pause_plan.rs` (the reducer and the plan),
`weto-sys/src/process_signaler.rs` and `process_registry.rs` (the boundary),
`weto-config/src/stopped.rs` (the ledger), `weto-guard/src/controller.rs` and `enforcer.rs`
(the behaviour), `weto-app/src/state.rs` (the journal writer).

- `WetoCore`: `GuardMachine.swift` (the reducer — `GuardPhase`, `GuardInput`, `GuardEffect`),
  `PausePlan.swift` (`PausePlanner`), `GuardPolicy.swift` (`UnprovenReason`/`UnsafeEvidence`
  split), `Model/NetworkPhases.swift`, `Model/CheckEvent.swift`
- `WetoSystem`: `ProcessSignaler.swift` (`ProcessSignaling`, was `ProcessKilling`),
  `TerminalLocator.swift` (`TerminalLocating`)
- `WetoShared`: `GuardController.swift` (owns the one live `GuardMachine`), `GuardVM.swift`
  (pause/resume enactment, journal episodes, `pausedProcesses`, `pauseDeadline`),
  `ProcessEnforcer.swift` (`pause`/`resume`/`resumeOrphans`/`terminate`), `StoppedLedger.swift`,
  `GuardNotifying.swift`, `CheckLogStore.swift`, `PopupPresenting.swift`
- `WetoMenuBar`: `StatusPopupView.swift` (three explanation lines, pause badges),
  `MenuBarPopupPresenter.swift` (opens the popup from a notification tap)
- `WetoDesign`: `WetoPauseBadge.swift`, `WetoTokens.controlHeightCompact`,
  `WetoPillButtonStyle`'s `.controlSize(.small)` support
- Shared: `shared/fixtures/guard-transitions.json` (new), `shared/fixtures/guard-policy.json`
  (version 4), `shared/fixtures/journal-export.json` (version 4, `schemaVersion` 3)

## Changes
- Added: `GuardPhase` — six phases (`disabled`, `verifying`, `protected`, `interference`,
  `paused`, `danger`), five user-visible titles (`protected`/`interference` share «На страже»).
  `GuardMachine.apply(_:at:)` is the only place a phase transition happens.
- Added: `PausePlan`/`PausePlanner` — stop order is shell (if the target is a foreground job of
  an interactive shell) → target → descendants by depth; resume is the exact reverse. Verified on
  zsh and bash 3.2 (the reverse order makes bash reclaim the tty and the target stops on
  `SIGTTIN`).
- Added: `StoppedLedger`/`stopped.json` — the record of "who did we SIGSTOP", read once on
  `GuardVM.start()` so a weto crash cannot leave a target frozen forever.
- Added: `GuardNotifying.notifyBackgrounded` and the "Показать терминал" popup affordance
  (`TerminalLocating`) — a paused terminal target that loses its foreground job otherwise just
  vanishes from its terminal with zero explanation.
- Added: `CheckEvent`/`CheckLogStore` — a second, 50-entry journal for connectivity-check
  *attempts* (trigger + outcome), independent of the kill journal, which only ever hears about
  processes actually terminated. `startupRecovery` is the one trigger whose only witness is this
  journal — `ledgerUnreadable` (the ledger did not decode) and `standingProcessesRemain` (entries
  survived the recovery, so the obligation is still open).
- Renamed: `ProcessKilling` → `ProcessSignaling` (`.kill`/`.stop`/`.resume`, delivered strictly in
  list order); `ProcessKiller.swift` → `ProcessSignaler.swift`.
- Renamed: `UnsafeReason` → `UnprovenReason` (pauses) + `UnsafeEvidence` (kills).
- Removed: `GuardPolicy.pendingVerification`, `Constants.silenceToleranceProbes`,
  `UnsafeReason.vpnAppNotChosen`/`.verificationPending` — a lost verdict is a reducer input
  (`.verdictLost`) now, not a policy outcome, and there is no tolerance window any more (see
  amendment below).
- Modified: `StatusPresentation` moved its title/explanation logic to read `GuardPhase` and added
  `explanation(for:remainingPause:)` (three lines: what weto did / why / what's next) and
  `shouldExplain(_:)`.

### Amendment 2026-09-09: no tolerance, no standing "Проверка"
The first version of this feature shipped with two extra knobs: tolerate `silenceToleranceProbes`
(2) consecutive failed probes before pausing, and treat "Проверка" itself as a standing phase with
its own 60 s countdown starting at a cold start or a path change. The owner removed both after
watching the running app: the standing "Проверка" stopped targets on a second VPN client
reconnecting on its own (not evidence of anything), and the tolerance window let targets run with
*no verdict at all* for up to two probe intervals (≈10 s) to avoid that — a worse trade than the
~5 s window it was trying to avoid. The rule is now "wait for the answer, then act on it": a cold
start or path change asks for a probe and changes nothing while it is in flight; the first
`unproven` result pauses immediately, with no count and no window. `GuardPhase.verifying` carries
only a cause, no moment — nothing is timed from it. Wording landed in commit `80be667`.

## Risks
- **The pause window is real and accepted, not a bug.** Between a path change (or cold start) and
  the probe's answer, targets run for up to ~5 s with no verdict. This was traded deliberately
  against the previous "stop first, ask later", which stopped targets on every flap of a
  perfectly healthy VPN.
- **Pid reuse is the recurring hazard on both the pause and resume sides.** `StoppedLedger`
  entries are pid **and** `executablePath`; `resumeOrphans` and `ProcessEnforcer.pause`'s
  already-stopped check both re-verify the path before trusting a pid.
- **A pause episode's staleness diagnosis must survive resolution.** It is captured once, when the
  episode opens, and reused verbatim when the episode resolves — recomputing it at resolution time
  would silently erase it, since the controller only carries a staleness diagnosis while actually
  `.paused`.
- **Linux divergence is intentional but must stay a documented row, not silence.** `Pending`/
  `Unproven` still kill on Linux, so they cannot borrow the macOS wording («Проверяю выход»/«Выход
  не подтверждён») without lying about what happened to the targets — see
  `modules/linux-guard.md`.

## How to test
- [ ] `swift test --filter GuardMachineTests` — the reducer against `guard-transitions.json`.
- [ ] `swift test --filter GuardVMTests` — pause/resume enactment, journal episodes, staleness
      survival across resolution, watchdog behaviour while paused.
- [ ] `swift test --filter ProcessSignalerTests` — signal order and `ESRCH`-as-delivered.
- [ ] `swift test --filter StoppedLedgerTests` — corrupted-file readout, add/remove/clear.
- [ ] A real pause: silence ipinfo/confirmation while a target runs → target gets `SIGSTOP`
      within one probe, popup shows «Выход не подтверждён» with a live countdown, target resumes
      on the next safe probe or is killed at the 60 s ceiling.
- [ ] Kill `weto` while a target is paused, relaunch → target gets `SIGCONT` on startup
      (`resumeOrphans`), or, if `stopped.json` is corrupted, a `startupRecovery`/`ledgerUnreadable`
      entry appears in the check-journal.
- [ ] Same, but with the target *backgrounded* (it answers the startup `SIGCONT` with a stop) →
      the popup shows its badge with the `fg` hint and one
      `startupRecovery`/`standingProcessesRemain` entry appears in the check-journal;
      the terminal does not keep printing `suspended (tty input)` forever.
- [ ] A paused terminal target loses its foreground job (backgrounded) → notification with
      "Показать терминал" fires; the button activates the hosting terminal app.
- [ ] Linux: same scenarios end the same way — see `linux/docs/manual-check.md` §3 and §3а.
      The screen still shows the interim titles and no pill; that is the remaining gap, not a bug.

## Related modules
- modules/weto-core.md
- modules/weto-system.md
- modules/weto-shared.md
- modules/weto-menubar.md
- modules/weto-design.md
- modules/linux-guard.md
