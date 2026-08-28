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
- `macos/Sources/WetoSystem/NetworkSnapshotReader.swift` — one question: who carries the traffic
- `macos/Sources/WetoSystem/RouteProbe.swift` — `RouteProbing`, `KernelRouteProbe`, `InterfaceAddresses`
- `macos/Sources/WetoSystem/NetworkEventSource.swift`
- `macos/Sources/WetoSystem/SearchPaths.swift` — `PATH` логин-шелла для поиска целей по имени
- `macos/Sources/WetoSystem/GeoProbe.swift`
- `macos/Sources/WetoSystem/NetworkPathReporter.swift` (also `NetworkPathReporting`)
- `macos/Sources/WetoSystem/HTTPFetching.swift`
- `macos/Sources/WetoSystem/ProcessRegistry.swift`
- `macos/Sources/WetoSystem/ProcessKiller.swift`
- `macos/Sources/WetoSystem/TargetResolver.swift`
- `macos/Sources/WetoSystem/KeychainStore.swift` (also `SecretStoring`, `SecretStoreError`, `TokenBox`)
- `macos/Sources/WetoSystem/FlagImageStore.swift`
- Tests: `macos/Tests/WetoSystemTests/{GeoProbeTests,RouteProbeTests,NetworkSnapshotReaderTests,NetworkEventSourceTests,FlagImageStoreTests,ProcessTests,KeychainStoreTests}.swift`

## Entry points
- `NetworkSnapshotReading.snapshot() → NetworkSnapshot` — sync, no throws; kernel route probe.
- `NetworkEventSourcing.start(handler: @Sendable (GuardTrigger) -> Void)` / `.stop()`
- `GuardTrigger` — `.networkPath`, `.dynamicStore`, `.route`, `.wake`, `.appLaunched(bundleID:)`,
  `.appTerminated(bundleID:)`, `.tick`, `.geoSchedule`
- `GeoProbing.probe() async → GeoProbeReport` (`GeoProbe` is an `actor`); the guard verdict is
  `report.outcome`, the popup reads the per-service breakdown
- `NetworkPathReporting.hasPath → Bool` — `NWPathMonitor.currentPath`, no request of its own
- `HTTPFetching.fetch(from:headers:) async throws → HTTPResponse`; impl `URLSessionHTTPFetcher(timeout:)`.
  The whole answer — body, status and duration — because the journal cannot tell a timeout from a
  429 from a provider stub page returning 200 by a parsed result: parsing never happens on failure.
  `HTTPFetchError` carries the response for the same reason: the body of a 429 is what explains it.
- `ProcessLocating.allProcesses(includeArguments:) → [ProcessSnapshot]`,
  `.allProcesses()` (convenience, argv off), `.bundlePath(forBundleID:) → String?`
- `ProcessKilling.kill(pids: [Int32]) → [KillResult]` (`KillResult.isTerminated`)
- `TargetResolving.resolve(_ entry: String) → TargetRule?`
- `SecretStoring.read(account:) → String?`,
  `.write(_:account:) → Result<Void, SecretStoreError>`
- `TokenBox.value` — lock-guarded `String?`, the bridge that lets `GeoProbe` read a live token
- `FlagImageStore.shared.image(for:) → NSImage?` — reads the bundled set, no network
- `KernelRouteProbe.outgoingRoute() → OutgoingRoute?`, `InterfaceAddresses.all()/.owner(of:)`

## Dependencies
- System frameworks: `SystemConfiguration` (`SCDynamicStore`), `Network` (`NWPathMonitor`),
  `AppKit` (`NSWorkspace`), `Security` (Keychain), `Darwin` (`libproc`, `sysctl`, `kill`)
- libproc/sysctl calls: `proc_listallpids`, `proc_pidpath`, `proc_pidinfo`+`PROC_PIDTBSDINFO`,
  `CTL_KERN`/`KERN_PROCARGS2`
- External APIs: `v4.api.ipinfo.io/lite/me` (Bearer token), `free.freeipapi.com`,
  `get.geojs.io`. The ipinfo host is also the route probe's destination.
- Keychain: service `com.weto.ipinfo`, account `token` (service injected by caller)
- Filesystem: none on the geo/flag path — flags come from the app bundle (`shared/flags`)
- Internal: `WetoCore` only (`NetworkSnapshot`, `ProcessSnapshot`, `TargetRule`, `GeoOutcome`,
  `IPAddress`, `GeoResponses`, `Constants`). No dependency on `WetoShared` — direction is one-way.
- Consumers: `AppCoordinator` (wires the production set), `GuardVM`/`GuardController`/
  `ProcessEnforcer`, `SettingsStore` + `Maintenance` (Keychain), `MenuBarLabel` (flags)

## Side effects
<!-- generated, verify -->
- Sends SIGKILL (no SIGTERM stage) to arbitrary pids via `ProcessKiller`.
- Network calls per `GeoProbe.probe()`: one ipinfo request, plus a confirmation request only when
  the address is new or the soft ceiling (60 s) has passed. When ipinfo refuses, one request to the
  geojs "who am I" endpoint instead — the address is what proves the verdict may be reused.
- Registers a `CFRunLoopSource` on the **main** run loop, an `NWPathMonitor` on private queue
  `com.weto.events`, and two `NSWorkspace` notification observers (`didWake`,
  `didLaunchApplication`). All are torn down in `stop()`, which `start()` calls first and
  `deinit` calls too.
- Keychain item add/update/delete under the injected service name.
- Creates the flag cache directory and writes downloaded `.svg` files into it.
- Reads the first two bytes of candidate executables (shebang sniffing in `TargetResolver`).

## Invariants / assumptions
- **«Is there a network at all» costs nothing.** `NetworkPathReporter` answers from a running
  `NWPathMonitor`, never with a probe request of its own. The popup shows that line only when
  something failed — it is the answer to "is my VPN to blame, or the service?".
- **A refused confirmation keeps its reason.** When both confirmers fail, the report carries
  the failure of the primary one (`free.freeipapi.com`), so an exhausted quota does not read
  as a generic outage.
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
  asks for argv only when at least one rule is `.script`. The full sweep of ~820 processes is
  ~2 ms (~5 ms with argv) and runs every 250 ms while unsafe, so this is a hot path.
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
- **`FlagImageStore.image(for:)` is synchronous and never touches the network.** The set ships
  in the bundle, so the first country renders without a round trip. The store used to fetch from
  a CDN and cache to disk: `cdn.jsdelivr.net` is blocked in Russia, and the download woke nobody —
  a flag sat in the cache unshown until the next observable state change.
- **The traffic carrier is asked of the kernel, never of the network configuration.**
  `State:/Network/Global/IPv4` is computed by `configd` from *network services*, and a tunnel
  opened outside NetworkExtension has no service at all: `scutil --nc list` is empty for it,
  `Setup:/Network/Service/…` has no entry, and `PrimaryInterface` names the underlying Wi-Fi while
  every public packet already leaves through `utun6`. Verified on a live machine. Dumping the
  default route is no better — such a client may not claim the default route at all, laying down
  prefix routes instead (`route get default → en0`, `route get 8.8.8.8 → utun6`).
- **The probe destination is the ipinfo host, not a fixed public address.** Clients exclude
  individual addresses from the tunnel: on the owner's machine `1.1.1.1` is pinned to `en0` by an
  explicit route, so probing it would declare a healthy tunnel broken. Ask about the address the
  verdict request will actually travel to.
- **Name resolution never blocks the guard.** The snapshot is taken every tick and DNS answers in
  seconds, so resolution runs on its own queue; the last known address survives a resolver outage,
  and `unresolved` is reported only when no address was ever obtained. A blinking resolver must not
  invalidate the verdict and kill targets.
- **Route changes are only visible on `PF_ROUTE`.** A client that edits routes directly touches
  neither `Global/IPv4` nor any service, so `SCDynamicStore` notifications stay silent. Bringing up
  a tunnel adds routes by the hundred, so the burst is coalesced into one event.

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
- **`proc_listallpids` counts pids, it does not count bytes.** The `buffersize` argument is in
  bytes, but the return value is already divided by `sizeof(int)` inside libproc. Dividing it
  again left exactly a quarter of the list — and the *newest* quarter, because the kernel walks
  `allproc` from newest to oldest. Anything older than the last ~200 launches was invisible:
  a long-lived target was never killed and never listed as running, and a VPN app opened a week
  ago read as closed. Every existing test spawned its process moments before the sweep, so none
  of them saw it; the guard is `launchd` (pid 1), which must always be in the list.
- **`proc_listallpids` races.** Capacity is queried, then over-allocated by 64 slots; processes
  spawning between the two calls can still be missed on that sweep.
- **`kill` returning `EPERM`** (root-owned target) is a genuine, unrecoverable failure that must
  surface to the user, unlike `ESRCH`.
- **Keychain is unavailable in unbundled runs** (`swift run WetoMenuBar`, and partly under
  `xctest`): `read` returns `nil`, so the token looks unset and the probe reports
  "no ipinfo token".
- **`RouteProbeTests` and `NetworkSnapshotReaderTests` read the live machine.** The route table
  cannot be faked, so they compare the probe against `/sbin/route -n get` and check that the
  outgoing address belongs to the named interface. They skip — never fail — when the machine has
  no route out; asserting a specific interface would make the suite machine-dependent.
- **`GeoProbe` confirmation order** (freeipapi first, geojs as fallback) is a measured choice,
  not an arbitrary one — see the rate-limit reasoning in `ARCHITECTURE.md`.
- **The flag set must cover every two-letter code a geo service can name.** A gap shows up as a
  blank menu bar icon, not as a red test — `FlagImageStoreTests` walks the system's region list for
  exactly that reason. The set is regenerated by `shared/tools/sync-flags.sh`; the copy under
  `macos/Sources/WetoDesign/Flags` is generated and must not be edited by hand.

## Related docs
- `.claude/rules/ARCHITECTURE.md` — module index and the invariants shared by both platforms
- `AGENTS.md` — boundary invariant and the domain traps summarised above
- `bugs/tunnel-without-network-service.md` — why the route owner is asked of the kernel
- `decisions/vpn-app-instead-of-tunnel.md` — why there is no tunnel picker any more
- `decisions/geo-confirmation-services.md` — the request budget this module spends
