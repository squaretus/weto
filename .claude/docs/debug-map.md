# Debug Map

<!-- Add entries as recurring bug categories surface:
     ## If X is broken — see file1, file2, serviceY -->

## If targets die while the VPN looks perfectly healthy

Read the journal first — the reason is stored per episode and it splits the search in two.
The ring buffer lives in `UserDefaults(suiteName: "com.weto.shared")` under `eventLog`
(macOS: `~/Library/Preferences/com.weto.shared.plist`, JSON inside; Linux:
`~/.local/state/weto/journal.json`).

- **`verificationPending` («Подключение ещё не проверено»)** — the previous verdict was
  declared stale, and the guard went fail-closed before asking the network. Suspect the
  freshness pair: `GuardController.evaluate`/`beginNetworkVerification` and
  `NetworkSnapshot.verdictFingerprint` (Linux: `controller.rs::run`,
  `network.rs::verdict_fingerprint`). Anything entering the fingerprint that the verdict does
  not actually depend on shows up exactly like this — that is how a second VPN reconnecting
  beside the chosen tunnel used to kill the targets.
- **`vpnAppNotChosen` / `vpnAppNotRunning`** — a local reason, no network involved. The suspects
  are the process scan and the rule: `ProcessEnforcer.vpnAppRule` (resolution follows symlinks and
  version-numbered paths, and is refreshed every 2 s) and `ProcessMatcher`. A client that updated
  itself and moved to a new path is the usual trap.
- **`verificationPending` right after the tunnel came up or went down** — the traffic carrier
  changed, so the fingerprint changed. Suspects: `KernelRouteProbe` (is the ipinfo host resolved?
  `out=-` means it is not) and the `PF_ROUTE` subscription.
- **`geoUnavailable` / `confirmationUnavailable`** — the boundary answered badly. `GeoProbe`,
  `GeoFailure`, and the rate limits in `decisions/geo-confirmation-services.md`.

Past failures worth reading before guessing: `bugs/tunnel-without-network-service.md`
(a healthy tunnel reported as bypassed, and third-party 429s killing targets).
