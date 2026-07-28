# WetoSystem

## Purpose
Adapters to macOS. Every OS-facing capability the guard needs (network configuration, network
events, geo lookup over HTTP, process enumeration, process termination, target resolution,
Keychain, flag cache) lives here behind a protocol. This is the only layer allowed to import
`SystemConfiguration`, `Network`, `AppKit`, `Darwin`/`libproc`, `Security` and to use
`URLSession` — the boundary that keeps `WetoCore` pure. Consequently these protocols are the
only legitimate mocking points in the whole test suite; nothing inside `WetoCore` or
`WetoShared` is ever substituted.

## Key files
- `Sources/WetoSystem/NetworkSnapshotReader.swift`
- `Sources/WetoSystem/NetworkEventSource.swift`
- `Sources/WetoSystem/GeoProbe.swift`
- `Sources/WetoSystem/HTTPFetching.swift`
- `Sources/WetoSystem/ProcessRegistry.swift`
- `Sources/WetoSystem/ProcessKiller.swift`
- `Sources/WetoSystem/TargetResolver.swift`
- `Sources/WetoSystem/KeychainStore.swift` (also `SecretStoring`, `SecretStoreError`, `TokenBox`)
- `Sources/WetoSystem/FlagImageStore.swift`
- Tests: `Tests/WetoSystemTests/{GeoProbeTests,NetworkSnapshotReaderTests,NetworkEventSourceTests,ProcessTests,KeychainStoreTests}.swift`

## Entry points
- `NetworkSnapshotReading.snapshot() → NetworkSnapshot` — sync, no throws; `SCDynamicStore`.
- `NetworkEventSourcing.start(handler: @Sendable (GuardTrigger) -> Void)` / `.stop()`
- `GuardTrigger` — `.networkPath`, `.dynamicStore`, `.wake`, `.appLaunched(bundleID:)`, `.tick`
- `GeoProbing.probe() async → GeoOutcome` (`GeoProbe` is an `actor`)
- `HTTPFetching.data(from:headers:) async throws → Data`; impl `URLSessionHTTPFetcher(timeout:)`
- `ProcessLocating.allProcesses(includeArguments:) → [ProcessSnapshot]`,
  `.allProcesses()` (convenience, argv off), `.bundlePath(forBundleID:) → String?`
- `ProcessKilling.kill(pids: [Int32]) → [KillResult]` (`KillResult.isTerminated`)
- `TargetResolving.resolve(_ entry: String) → TargetRule?`
- `SecretStoring.read(account:) → String?`,
  `.write(_:account:) → Result<Void, SecretStoreError>`
- `TokenBox.value` — lock-guarded `String?`, the bridge that lets `GeoProbe` read a live token
- `FlagImageStore.shared.image(for:) → NSImage?`, `.prefetch(_:)`

## Dependencies
- System frameworks: `SystemConfiguration` (`SCDynamicStore`), `Network` (`NWPathMonitor`),
  `AppKit` (`NSWorkspace`), `Security` (Keychain), `Darwin` (`libproc`, `sysctl`, `kill`)
- libproc/sysctl calls: `proc_listallpids`, `proc_pidpath`, `proc_pidinfo`+`PROC_PIDTBSDINFO`,
  `CTL_KERN`/`KERN_PROCARGS2`
- External APIs: `v4.api.ipinfo.io/lite/me` (Bearer token), `free.freeipapi.com`,
  `get.geojs.io`, `cdn.jsdelivr.net` (HatScripts/circle-flags SVG)
- Keychain: service `com.weto.ipinfo`, account `token` (service injected by caller)
- Filesystem: `~/Library/Caches/com.weto.app/flags-circle/`
- Internal: `WetoCore` only (`NetworkSnapshot`, `ProcessSnapshot`, `TargetRule`, `GeoOutcome`,
  `IPAddress`, `GeoResponses`, `Constants`). No dependency on `WetoShared` — direction is one-way.
- Consumers: `AppCoordinator` (wires the production set), `GuardVM`/`GuardController`/
  `ProcessEnforcer`, `SettingsStore` + `Maintenance` (Keychain), `MenuBarLabel` (flags)

## Side effects
<!-- generated, verify -->
- Sends SIGKILL (no SIGTERM stage) to arbitrary pids via `ProcessKiller`.
- Network calls on every `GeoProbe.probe()`: one ipinfo request plus one confirmation request
  (freeipapi, then geojs on failure). Nothing is cached, by design.
- Registers a `CFRunLoopSource` on the **main** run loop, an `NWPathMonitor` on private queue
  `com.weto.events`, and two `NSWorkspace` notification observers (`didWake`,
  `didLaunchApplication`). All are torn down in `stop()`, which `start()` calls first and
  `deinit` calls too.
- Keychain item add/update/delete under the injected service name.
- Creates the flag cache directory and writes downloaded `.svg` files into it.
- Reads the first two bytes of candidate executables (shebang sniffing in `TargetResolver`).

## Invariants / assumptions
<!-- generated, verify -->
- **Read-only core boundary.** Nothing here may be imported by `WetoCore`; the arrow points
  one way. Everything is exposed as a protocol so `WetoShared` tests can substitute it.
- **VPN classification never looks at the service name.** `Setup:/…/Interface` `Type` must be
  `VPN`, `IPSec`, or `PPP` with `SubType` in `{L2TP, PPTP}`. A Wi-Fi service named "VPN" must
  not qualify, and a renamed tunnel must keep qualifying.
- **Failure degrades to an empty snapshot, not to a throw.** If `SCDynamicStoreCreate` fails,
  `snapshot()` returns `NetworkSnapshot(services: [], primaryServiceUUID: nil)` — the resolver
  reads that as `.down`, so the fail-closed policy still fires. Never "optimise" this into a
  cached last-good snapshot.
- **A service with no `UserDefinedName` is dropped entirely** from the snapshot and therefore
  from the settings picker.
- **`Setup:` vs `State:` split is deliberate:** configuration (name, interface type) comes from
  `Setup:/Network/Service/<uuid>/…`, liveness (`InterfaceName`, `PrimaryService`) from
  `State:/…`. Mixing them makes a configured-but-down tunnel look up.
- **Caching is forbidden on the geo path.** `URLSessionHTTPFetcher` uses an ephemeral
  configuration, `urlCache = nil`, and `reloadIgnoringLocalAndRemoteCacheData` on both the
  configuration and each request; `GeoProbe` keeps no state between probes. A cached 200 would
  freeze the reported country while the real exit node changed.
- **The IP from ipinfo is validated by `IPAddress.isValid` before it is interpolated into the
  confirmation URLs.** A string from the network must never reach a URL unchecked.
- **A failed confirmation is not an error.** Both confirmers failing yields
  `.resolved` with `confirmedCountry == nil`; turning that into a kill decision is
  `GuardPolicy`'s job (strict fail-closed), not the probe's.
- **The token is read per probe through a closure** (`TokenBox`), so editing it in settings takes
  effect without rebuilding `GeoProbe`. An empty/absent token short-circuits to `.unavailable`
  with zero network traffic.
- **Confirmation gets its own fetcher with a shorter timeout** (`geoConfirmationTimeoutSeconds`,
  2.5s vs 5s): it extends the fail-closed window, so it must not wait as long as ipinfo.
- **argv is opt-in.** `allProcesses(includeArguments: false)` is the default; `ProcessEnforcer`
  asks for argv only when at least one rule is `.script`. The full sweep of ~230 processes is
  ~5 ms and runs every 250 ms while unsafe, so this is a hot path.
- **argv is kept as separate elements, never joined.** Script targets are matched by exact
  equality of one argv element (`ProcessMatcher` uses set disjointness against `launchPaths`);
  substring matching killed look-alike wrappers and processes that merely mentioned the path.
- **argv buffer size is asked from the kernel** (`sysctl` with `nil` buffer) and capped at
  `ARG_MAX`, not preallocated — a fixed 256 KiB per process cost tens of MB on the hot path.
- **`ESRCH` counts as terminated.** `KillResult.isTerminated` is true for `nil` and `ESRCH`:
  a process that vanished between enumeration and kill is a success, not a failure.
- **`TargetResolver` resolves symlinks into `path` and keeps the original candidate in
  `launchPaths`.** `TargetRule.init` merges `path` into `launchPaths`, so both spellings match.
  This is what makes `/usr/bin/nano` work when `proc_pidpath` reports `pico`.
- **Shebang ⇒ `.script` kind ⇒ argv matching.** A two-byte `#!` read decides the kind; for
  script targets `proc_pidpath` points at the interpreter (`node` for `qwen`), so path matching
  would take out every Node process.
- **Resolution order is fixed:** `.app` path suffix → bundle identifier (only when the entry
  has no `/` and contains `.`) → executable in a hardcoded search list (`/opt/homebrew/{bin,sbin}`,
  `/usr/local/{bin,sbin}`, `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`).
- **`PATH` is not consulted** — the search list is hardcoded. Anything outside it must be
  entered as an absolute path.
- **Keychain writes report failures.** `write` returns `Result`, and a swallowed error used to
  present an in-memory-only token as saved; `errSecItemNotFound` on delete is success.
- **`FlagImageStore.image(for:)` is synchronous and returns `nil` until `prefetch` lands.**
  The UI must render a placeholder and re-read later; the store never blocks on the network.

## Failure hotspots
<!-- generated, verify -->
- **`NetworkEventSource` lifecycle and threading.** `SCDynamicStoreContext` holds
  `Unmanaged.passUnretained(self)` with no retain/release callbacks; correctness depends on
  `stop()` removing the run loop source before the object dies. Callbacks arrive from at least
  three places (private queue for `NWPathMonitor`, main run loop for `SCDynamicStore`,
  notification queue for `NSWorkspace`), so the handler is read under `NSLock` — any new
  emitter must go through `emit`. The `SCDynamicStore` source is attached to
  `CFRunLoopGetMain()`, so `start()` is useless without a live main run loop.
- **`NWPathMonitor` fires once immediately on `start`**, so the first trigger arrives before any
  real network change; code that treats the first event as "something changed" misbehaves.
- **Silently invisible processes.** `allProcesses` skips any pid where `proc_pidpath` returns
  ≤ 0 (other users, SIP-protected, races). A target running under a different user is simply
  never seen — this reads as "the kill didn't work".
- **`KERN_PROCARGS2` parsing.** argc is decoded byte-wise little-endian from the first 4 bytes,
  the first NUL-separated chunk (the exec path) is dropped, then `argc` chunks are taken. Any
  change to the drop/prefix arithmetic silently shifts argv and breaks script matching.
- **`proc_listallpids` races.** Capacity is queried, then over-allocated by 64 slots; processes
  spawning between the two calls can still be missed on that sweep.
- **`kill` returning `EPERM`** (root-owned target) is a genuine, unrecoverable failure that must
  surface to the user, unlike `ESRCH`.
- **Keychain is unavailable in unbundled runs** (`swift run WetoMenuBar`, and partly under
  `xctest`): `read` returns `nil`, so the token looks unset and the probe reports
  "no ipinfo token".
- **`NetworkSnapshotReaderTests` read the live machine.** They assert structural invariants
  (uniqueness, non-empty names, VPN qualification) rather than fixed values; adding an
  assertion about a specific service makes the suite machine-dependent.
- **`GeoProbe` confirmation order** (freeipapi first, geojs as fallback) is a measured choice,
  not an arbitrary one — see the rate-limit reasoning in `ARCHITECTURE.md`.
- **`FlagImageStore` uses `URLSession.shared`** (unlike the geo fetchers) and dedupes concurrent
  downloads through an `inFlight` set; a download that fails leaves no negative cache, so
  `prefetch` retries on the next call.

## Related docs
- `.claude/rules/ARCHITECTURE.md` — module index, "Ключевые контракты", check ordering
- `.claude/CLAUDE.md` — boundary invariant and the domain traps summarised above
- No `features/`, `bugs/`, or `decisions/` entries reference this module yet.
