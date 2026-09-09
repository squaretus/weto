# Debug Map

<!-- Add entries as recurring bug categories surface:
     ## If X is broken — see file1, file2, serviceY -->

## If targets die while the VPN looks perfectly healthy

Read the journal first — the reason is stored per episode and it splits the search in two.
On macOS it is a file, not `UserDefaults` any more:
`~/Library/Application Support/weto/journal.json` (Linux: `~/.local/state/weto/journal.json`).

Killing requires *proof* (`UnsafeEvidence`) — everything else pauses (`UnprovenReason`), so a
`kind: .terminated` record with no clear local cause is the one worth chasing here; a
`kind: .paused` record for the same episode means the guard is only *waiting*, not accusing
anything, and belongs in the section below instead.

- **A lost verdict (no evidence yet, `GuardPhase.verifying`, «Проверяю выход»)** — the previous
  verdict was declared stale by a fingerprint or revision change. Targets keep running here (this
  is the whole point of the 2026-09-09 re-spec — see `decisions/pause-instead-of-kill.md`); if
  something died anyway, the bad actor is a `.paused` episode's ceiling (60 s with no answer,
  `UnsafeEvidence.pauseExpired`) or actual proof, not the lost verdict itself. Suspect the
  freshness pair: `GuardController.evaluate`/`applyLatestNetworkOutcome` and
  `NetworkSnapshot.verdictFingerprint` (Linux: `controller.rs::run`,
  `network.rs::verdict_fingerprint`). Anything entering the fingerprint that the verdict does
  not actually depend on shows up as spurious pauses/kills — that is how a second VPN reconnecting
  beside the chosen tunnel used to kill the targets outright, before the pause model existed.
- **`vpnAppNotRunning`** (`UnsafeEvidence`, always kills — an unchosen app is not a reason for
  anything) — a local reason, no network involved. The suspects are the process scan and the
  rule: `ProcessEnforcer.vpnAppRule` (resolution follows symlinks and version-numbered paths, and
  is refreshed every 2 s) and `ProcessMatcher`. A client that updated itself and moved to a new
  path is the usual trap.
  Before suspecting either, check that the sweep sees the process at all: compare
  `NSWorkspace.runningApplications` (or `proc_pidpath` on the pid) against the list
  `ProcessRegistry.allProcesses` returns. A pid that exists but is absent from the list means the
  enumeration is truncated — `bugs/a-quarter-of-the-process-list.md`. The same truncation makes a
  long-lived target silently unkillable, which looks like nothing at all rather than a wrong reason.
- **A lost verdict right after the tunnel came up or went down** — the traffic carrier changed,
  so the fingerprint changed. Suspects: `KernelRouteProbe` (is the ipinfo host resolved? `out=-`
  means it is not) and the `PF_ROUTE` subscription. This alone only re-enters `verifying` (targets
  keep running); it becomes a kill only via a `.paused` episode's 60 s ceiling.
- **`notWhitelistedIP` / `notWhitelistedCountry` («… не входит в белый список»)** — not a
  malfunction: a non-empty whitelist is in the settings and the exit matched none of it. The list
  lives under `allowedCountryCodes` / `allowedIPRangeTexts` (Linux: `allowed_countries` /
  `allowed_ip_ranges` in `config.toml`); an empty one cannot produce these reasons. Which of the two
  reasons appears depends only on whether the list contains ranges — see `features/geo-whitelist.md`.
- **`geoUnavailable` / `confirmationUnavailable`** — the boundary answered badly. `GeoProbe`,
  `GeoFailure`, and the rate limits in `decisions/geo-confirmation-services.md`.

## If targets are stopped (SIGSTOP) but weto is not running

This is what weto crashing during a pause looks like from the outside: the targets froze and
nothing ever un-froze them because the process that owns the countdown is gone.

- Check `stopped.json` next to the journals
  (`~/Library/Application Support/weto/stopped.json`): a non-empty file after weto has been
  relaunched means `GuardVM.start() → ProcessEnforcer.resumeOrphans()` either has not run yet or
  refused every entry. `resumeOrphans` only sends `SIGCONT` when the live process at that pid is
  *still stopped* **and** *still has the same `executablePath`* — a pid reused by an unrelated
  process since the crash is deliberately left alone, which looks like "weto didn't resume it" but
  is the safe behaviour, not a bug.
- If the file itself does not decode, `StoppedFile.load()` returns `.corrupted` (read as empty, so
  startup is never blocked by it) and `GuardVM.start()` writes a `CheckEvent(trigger:
  .startupRecovery, outcome: .ledgerUnreadable)` into the check-journal
  (`~/Library/Application Support/weto/checks.json`) — that entry is the only trace that the
  "resume everyone we stopped" obligation went unmet this run. An entry that *survives* the
  recovery (the process is still stopped after its `SIGCONT`) writes a
  `standingProcessesRemain` entry with the same trigger and shows up as a badge with the `fg`
  hint in the popup — if a target is stopped after a relaunch and neither is there, the seeding
  in `GuardVM.surfaceRecovered` is the suspect.
- A target stuck stopped *while weto is running* is a different bug: check `GuardVM.phase.action`
  — if it is not `.pause`, `applyCurrentAction`/`pauseTargets` should not be touching it at all, and
  the suspect is `ProcessEnforcer.pause`'s "already stopped" de-dup (`StoppedIdentity`, keyed on
  pid **and** path — a stale ledger entry for a *different* process that reused the pid can mask a
  fresh target that genuinely needs `SIGSTOP`).

## If a target is not killed at all, or never shows up as running

The process sweep is the first suspect, not the policy: `ProcessRegistry.allProcesses` must return
every pid the kernel has (`launchd` is the cheap check), and only then does `ProcessMatcher`
matter. See `bugs/a-quarter-of-the-process-list.md`.

Past failures worth reading before guessing: `bugs/tunnel-without-network-service.md`
(a healthy tunnel reported as bypassed, and third-party 429s killing targets),
`bugs/a-quarter-of-the-process-list.md` (three quarters of the machine invisible to the guard).
