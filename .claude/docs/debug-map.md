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
- **`vpnDown` / `vpnNotPrimary`** — a local reason, no network involved. The snapshot itself
  is the suspect: `NetworkSnapshotReader` (`SCDynamicStore` + `getifaddrs`) and
  `VPNStatusResolver`. A user-space tunnel with no network service is the usual trap: the
  route owner has to be read by interface, not only by service.
- **`geoUnavailable` / `confirmationUnavailable`** — the boundary answered badly. `GeoProbe`,
  `GeoFailure`, and the rate limits in `decisions/geo-confirmation-services.md`.
