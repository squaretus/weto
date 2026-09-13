# Decision: pause without proof, kill only on proof

## Context

Two episodes from a real journal (`weto-journal-2026-09-08-1047.json`):

- 18:03:21Z — four processes killed with `verificationPending`; two seconds later the verdict
  came back safe (`203.0.113.177`, KZ, `utun5`).
- 19:31:51Z — 96 processes killed because ipinfo and geojs-self both timed out. The exit
  fingerprint (`utun5/198.18.0.1`) never changed, the VPN app was running, and the check log
  shows both services silent for three minutes straight — every probe timing out at ~7.5 s.

The code already told these situations apart (`verificationPending`, `.degraded(previous:)`,
`.unavailable`) but answered two of them the same way: SIGKILL. A real leak after a client
crash almost always moves the traffic carrier (`utun` → `en0`) and is caught by the
fingerprint without any geo. While the fingerprint is unchanged and the carrier is a `utun`,
a timeout means a black hole, not a leak.

## Decision

1. **Kill only on positive proof.** Proof is: the chosen VPN app is not running, the address is
   blacklisted, a blocked country, a country conflict, a whitelist miss, or the pause ceiling
   expired. Everything else — no verdict yet, ipinfo silent, confirmation silent, a different
   address named by the fallback — is *unproven* and pauses the targets (SIGSTOP) instead.
2. **Two axes, six phases, five titles.** Knowledge about the exit (none / safe / safe-but-silent /
   unreachable / unsafe) × action on targets (running / paused with a countdown / terminated
   with launch blocked) gives six `GuardPhase` cases: `disabled`, `verifying`, `protected`,
   `interference`, `paused`, `danger`. The title answers "am I protected?", not "why" — so
   `protected` and `interference` share one title. Five titles reach the user: **Охрана
   выключена**, **Проверяю выход**, **На страже** (both `protected` and `interference`),
   **Выход не подтверждён**, **Небезопасно**. «Помехи» names the `interference` phase
   internally (evidence and shield colour differ from `protected`) but is not a title the
   user ever sees. The reason is attached as evidence; it does not define the state. The
   policy stays a pure function (`GuardPolicy.decide` → safe / unproven / kill); the
   transitions live in a pure reducer (`GuardMachine`) owned by `GuardController`.
3. **The pause starts from a bad result, never from waiting for one.** «Проверка» is a *running*
   phase: a cold start and a path change invalidate the verdict and ask for a probe, and the
   answer decides. The first result that says «not proven» pauses the targets — there is no count
   of failed probes and no tolerance window. «Помехи» survives with evidence semantics only:
   ipinfo silent while the fallback names our *previous* address is an answer, not silence, so
   the targets run. A changed address from the fallback is not such an answer and pauses on the
   first probe.
4. **Pause ceiling 60 s**, counted from the moment the pause began. Safe verdict → SIGCONT;
   proof → SIGKILL; nothing within 60 s → SIGKILL with «подтверждение не получено». Nothing can
   extend it: «no verdict for this path» is not a result, and a path change under the pause
   neither resumes the targets nor restarts the countdown. Probes keep their rhythm.
5. **Pause is tree-wide, parent first; children born later are caught by the next sweep;
   processes already stopped (`T`) are never touched.** For a terminal target that is the
   foreground job of an interactive shell, the shell is stopped too — **shell first, then the
   target; resume: target first, then the shell** (verified on zsh and bash 3.2; the reverse
   order makes bash reclaim the tty and the target stops on SIGTTIN).
6. **Stopped pids are recorded on disk** (`stopped.json` next to the journals) and resumed on
   safe, on normal exit and on start after a crash.
7. **A settings change does not invalidate the verdict.** The decision is recomputed from the
   established reading synchronously; only a fingerprint change demands a probe. The revision
   still guards against a probe started under old settings.
8. **An unchosen VPN app is not a reason for anything**: the guard works on geo alone.

## Why this is not weaker

- The unsafe transitions that were immediate stay immediate: closing the client, a blocked
  country, a blacklisted address.
- A fingerprint change asks for a probe at once, and the answer arrives inside ~5 s; a bad
  answer pauses, and a paused process sends nothing. The previous «stop first, ask later»
  bought those five seconds at the price of stopping the targets on every path change of a
  perfectly healthy VPN — and it paid for them with a tolerance window that let the targets run
  *without any verdict at all* for two probes (≈10 s), which is longer than the window it saved.
- Strict fail-closed is preserved in the knowledge axis: no confirmation never yields *safe*.
  What changed is the action: a stopped process leaks nothing either, and it can be resumed.
- The ceiling turns an unresolved pause into the old behaviour after 60 s.
- «Опасно» is left only by a real probe result. Previously a path change moved it into
  «Проверка», which was a de-escalation while that phase was standing; now it would permit
  launching targets with no evidence at all, so no staleness cause lifts a proof.

## Consequences

- `UnsafeReason` is split into `UnsafeEvidence` (kills) and `UnprovenReason` (pauses);
  `verificationPending` and `vpnAppNotChosen` disappear. The shared policy fixture moves to
  version 4 and drops the `pendingVerification` function.
- New shared fixture `guard-transitions.json` pins the reducer for both platforms.
- The journal gains `kind: paused` with an outcome (`resolutionText`), `diagnostics.verdictOrigin`,
  per-phase request timings and `matchedBy` instead of `isDescendant`.
- Linux ports the core (policy, texts, formats) in the same change and the behaviour
  (SIGSTOP/SIGCONT, ledger, UI) in a follow-up; until then Linux treats *unproven* as the old kill.

## Amendment 2026-09-09 (owner, after looking at the running app)

Points 3 and 4 above are the amended ones; what they replaced was: tolerance of N = 2 failed
probes before pausing, and a standing «Проверка» whose own 60 s countdown started at a cold
start or a path change. Both are gone.

Why the owner changed the rules on the running app:

- The standing «Проверка» stopped the targets on things that are not evidence of anything.
  A second VPN client on the machine reconnects by itself, the carrier flaps, and every flap
  froze the work for as long as the probe took.
- The tolerance was the opposite mistake in the same trade: to avoid stopping on transient
  silence it let the targets keep running with no verdict for two probe intervals. Waiting for
  an answer is not evidence, and neither is a guess that the silence is temporary.

The new shape is one rule instead of two knobs: **wait for the answer, then act on it.**
The accepted cost, stated plainly: between a path change (or a cold start) and the probe's
answer there is a window of up to ~5 s in which the targets run without a verdict. The owner
has been told and accepts it. It is not a bug to be «fixed» by pausing earlier — pausing earlier
is precisely what was removed.

Consequences of the amendment:

- `Constants.silenceToleranceProbes` is gone; `GuardMachine` loses its `tolerance`, and
  `GuardPhase.interference` loses its `failures` counter.
- `GuardPhase.verifying` carries only a cause (no moment): nothing counts from it, and
  `pausedSince` belongs to «Пауза» alone.
- `guard-transitions.json` moves to version 2: `case.tolerance` and `phase.failures` are gone,
  `phase.cause` is checked, and `verifying` may be a starting phase.
- An episode of the journal cannot begin in «Проверка» any more, so `diagnostics.staleness`
  is computed where it is applied — at the bad result that opens the episode — and describes
  the exit at that moment. It is absent when there was nothing to lose (the exit did not move
  and the services simply went quiet); the exit itself is still in the record as its own
  fields. The popup wording for «Проверка» was fixed by the wording follow-up (`80be667`):
  it now reads «Проверяю выход», «Цели работают», with no countdown — a running phase reads
  as one.
