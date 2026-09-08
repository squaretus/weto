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
2. **Two axes, six states.** Knowledge about the exit (none / safe / safe-but-silent /
   unreachable / unsafe) × action on targets (running / paused with a countdown / terminated
   with launch blocked). User-visible states: **Выключено**, **Проверка**, **Защищено**,
   **Помехи**, **Пауза**, **Опасно**. The reason is attached as evidence; it does not define
   the state. The policy stays a pure function (`GuardPolicy.decide` → safe / unproven / kill);
   the transitions live in a pure reducer (`GuardMachine`) owned by `GuardController`.
3. **Tolerance before pausing.** With an unchanged fingerprint, a running VPN app and an
   established verdict, the first N consecutive failed probes change nothing (N = 2, ≈10 s at the
   5 s schedule). A changed address from the fallback gets no tolerance.
4. **Pause ceiling 60 s** in both «Проверка» and «Пауза». Safe verdict → SIGCONT; proof → SIGKILL;
   nothing within 60 s → SIGKILL with «подтверждение не получено». Probes keep their rhythm.
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
- A fingerprint change pauses at once, with no tolerance — the moment the carrier changes is
  exactly when a leak could start, and a paused process sends nothing.
- Strict fail-closed is preserved in the knowledge axis: no confirmation never yields *safe*.
  What changed is the action: a stopped process leaks nothing either, and it can be resumed.
- The ceiling turns an unresolved pause into the old behaviour after 60 s.

## Consequences

- `UnsafeReason` is split into `UnsafeEvidence` (kills) and `UnprovenReason` (pauses);
  `verificationPending` and `vpnAppNotChosen` disappear. The shared policy fixture moves to
  version 4 and drops the `pendingVerification` function.
- New shared fixture `guard-transitions.json` pins the reducer for both platforms.
- The journal gains `kind: paused` with an outcome (`resolutionText`), `diagnostics.verdictOrigin`,
  per-phase request timings and `matchedBy` instead of `isDescendant`.
- Linux ports the core (policy, texts, formats) in the same change and the behaviour
  (SIGSTOP/SIGCONT, ledger, UI) in a follow-up; until then Linux treats *unproven* as the old kill.
