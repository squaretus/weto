# WetoXPC

## Purpose
The only code shared between the unprivileged app and the root daemon: the XPC interface
(`WetoHelperProtocol`), the client that dials the privileged mach service, the mach service
name constant, and the mapping of daemon replies into UI-ready results.
It exists as a separate SPM target so that `WetoShared` and `WetoHelper` compile against
literally the same protocol declaration — a drifting interface between an app and a root
daemon fails at runtime as "connection accepted, method never answers", not at build time.

The surface is deliberately three methods wide. Every method here is executed by a root
process, so anything without a caller was removed rather than kept "just in case":
release checking lives in the app over plain HTTP (`UpdateVM`), not behind XPC.

## Key files
- `Sources/WetoXPC/WetoHelperProtocol.swift`
- `Sources/WetoXPC/WetoXPCClient.swift`
- `Sources/WetoXPC/UpdateService.swift`
- `Sources/WetoXPC/XPCConstants.swift`
- `Tests/WetoXPCTests/UpdateServiceTests.swift`

## Entry points
- `WetoXPCClient()` / `client.helper(errorHandler:) → WetoHelperProtocol?` — lazily creates
  an `NSXPCConnection(machServiceName:options: .privileged)` proxy; `nil` means the daemon is
  not installed or the proxy could not be cast.
- `WetoXPCClient.invalidate()` — tears the connection down; `deinit` invalidates too.
- `WetoHelperProtocol.performUpdate(reply:) → String?` — **no parameters by design**
- `WetoHelperProtocol.lastInstallFailure(reply:) → String?` — outcome of the last install the
  daemon already answered `nil` (= started) for; `nil` means "nothing to report"
- `WetoHelperProtocol.uninstallHelper(reply:) → String?`
- `UpdateService.install(helper:completion:) → InstallResult` (`.started` / `.failed`)
- `UpdateService.lastFailure(helper:completion:) → String?`
- `WetoXPCConstants.machServiceName` = `com.weto.helper` (pinned by
  `test_mach_service_name_is_pinned`)

## Dependencies
- Service: LaunchDaemon `com.weto.helper` (`/Library/LaunchDaemons/com.weto.helper.plist`,
  binary in `/Library/PrivilegedHelperTools/`) — the remote end, running as root
- Target deps: none. `UpdateInfo` no longer crosses the boundary, so the `WetoCore` dependency
  was dropped from both `Package.swift` and `UpdateService.swift` — the target is linked into
  a root process, and every dependency here would be code running as root
- System: `Foundation` / `NSXPCConnection` with `.privileged` (system-domain mach service)
- Consumers: `WetoShared/UpdateInstalling.swift` (`HelperUpdateInstaller`),
  `WetoShared/Maintenance.swift`, `WetoHelper/HelperDelegate.swift`, `WetoHelper/main.swift`
- DB / Queue / External API: none in this target — no HTTP, no `UserDefaults`, no Keychain

## Side effects
<!-- generated, verify -->
- Opens and holds a privileged XPC connection to `com.weto.helper`; the connection is dropped
  and forgotten on `invalidationHandler` / `interruptionHandler`, then re-created on the next
  `helper(...)` call. Nothing else in this module keeps state.
- No writes of its own. Every filesystem, network and `installer` effect happens on the daemon
  side (`WetoHelper`): `.pkg` download into `/var/db/weto/updates`, `installer -pkg`,
  removal of the daemon's plist/binary, `launchctl bootout system/com.weto.helper`.
- Calling `performUpdate` indirectly terminates both the app and the daemon: the package's
  installer unloads them mid-install, so the reply channel usually dies with the process.
- `lastInstallFailure` has no effects at all — it reads a string the daemon keeps in memory.
  It is the *only* channel through which a post-`started` failure reaches the user, and the
  app polls it every `Constants.installOutcomePollSeconds` (5 s) while the spinner is up.
- `uninstallHelper` indirectly makes further calls impossible — the mach service disappears.

## Invariants / assumptions
<!-- generated, verify -->
- **`performUpdate` accepts no URL, version or path.** The daemon re-queries GitHub itself and
  decides what to install. Any parameter here would mean an authorized process can ask root to
  install an arbitrary package. Same reason `UpdateInfo.downloadURL` travels app-ward only as
  display data — the daemon never reads a URL that came over XPC.
- **The surface stays minimal.** A method here is a thing an authorized process can ask root to
  do. `getHelperVersion`, `checkForUpdate`, `checkForUpdateForced` (and their `UpdateService`
  wrappers, plus `WetoXPCConstants.protocolVersion`) were removed for exactly that reason: no
  callers, yet executed as root. Do not add a method whose caller does not exist yet.
- `.started` is not "installed". It only means the daemon accepted the job; success is still
  never reported back (see Side effects) — the successful path is observed as the process
  dying. Only *failure* is reportable, and only by asking `lastInstallFailure`.
- `lastInstallFailure` reply `nil` means "nothing to report", not "success": the daemon keeps
  the string in memory only, so a restarted daemon has forgotten it
  (pinned by `test_late_failure_is_passed_through` / `test_no_late_failure_is_not_an_error`).
- `helper(...) == nil` and an `errorHandler` callback both mean "no mechanism available", which
  is different from "install failed" — `UpdateInstalling.requestInstall` encodes this as `nil`
  vs `.failed`. Collapsing the two would show a scary error when the daemon is simply absent.
  For `requestLastFailure` both collapse to `nil` on purpose: silence there is normal, because
  the daemon dies together with a successful install.
- Client-side authorization is not this module's job: the daemon vets callers by executable path
  (`WetoHelper/ClientAuthorization.swift`). This target must stay free of any "trust me" flag
  that the daemon could believe.
- The target must stay dependency-free — it is linked into a root process, so every added
  dependency is code running as root.

## Failure hotspots
<!-- generated, verify -->
- **Double reply.** A call can be answered both by the connection's `errorHandler` and by the
  daemon's own `reply`. `WetoXPCClient` does not deduplicate; the guard lives in the consumer
  (`AnsweredOnce` / `AnsweredOnceString` in `UpdateInstalling.swift`). New call sites that skip
  that wrapper will fire completions twice.
- **Silent hang.** The default `errorHandler` is `{ _ in }`. Calling `helper()` without a
  handler and awaiting a reply means no callback at all when the daemon is missing — the UI
  spinner stays forever.
- **No version handshake at all.** With `getHelperVersion` gone, a stale daemon left by a partial
  install is not detected by anyone: both sides just have to agree on `WetoHelperProtocol`.
  A method removed or renamed on one side only fails at runtime as "reply never arrives".
- **`lastInstallFailure` cannot distinguish "no failure" from "daemon gone".** Both are `nil` at
  the client boundary. If the daemon dies without recording anything and the app survives, the
  poll loop keeps returning `nil` and the spinner stays up until the app is quit.
  <!-- generated, verify --> In practice the installer's `preinstall` `killall`s the app in the
  same window, so this is expected to be unobservable.
- **Connection reuse after install.** The daemon dies during an update, so a cached proxy is
  guaranteed stale; correctness depends on the invalidation/interruption handlers actually
  clearing `connection`.
- `NSXPCConnection(options: .privileged)` looks up the system domain — a daemon installed into
  the user domain, or a `machServiceName` mismatch with the plist's `MachServices` key, yields
  the same symptom as "not installed at all".

## Related docs
- `.claude/rules/ARCHITECTURE.md` — section `### Автообновление`
- `modules/weto-helper.md` — the root end of this protocol
- `modules/weto-shared.md` — `UpdateInstalling` / `UpdateVM`, the only client
- `overview.md` — flow «Update: HTTP check in the app, root install in the daemon»
