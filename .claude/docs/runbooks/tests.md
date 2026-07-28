# Tests

How to run the two independent test layers of weto: XCTest suites via SwiftPM and shell contracts under `scripts/tests/`. No Docker, no Makefile — everything runs directly on the host (macOS 26+, Apple Silicon).

## Steps

### 1. XCTest suites (SwiftPM)

```bash
swift build                              # compile first, faster feedback on syntax errors
swift test                               # all five test targets
swift test --filter WetoCoreTests        # single target
swift test --filter GuardPolicyTests     # single class
swift test --filter test_written_secret_is_read_back   # single case
```

Test targets declared in `Package.swift` (`Tests/<name>/`):

| Target | Depends on | Covers |
| --- | --- | --- |
| `WetoCoreTests` | `WetoCore` | policy decisions (`GuardPolicy`, `GuardPolicyLocal`), `VPNStatusResolver`, `ProcessMatcher`, `IPRange`, `SemanticVersion`, `ReleasePackageURL`, geo response parsing |
| `WetoSystemTests` | `WetoSystem`, `WetoCore` | boundary adapters: `GeoProbe`, `KeychainStore`, `NetworkEventSource`, `NetworkSnapshotReader`, process listing |
| `WetoSharedTests` | `WetoShared`, `WetoCore`, `WetoSystem`, `WetoXPC` | VM layer: `GuardVM`, `UpdateVM`, `SettingsStore`, `EventLogStore`, `LaunchAgentController`, `Maintenance`, `StatusPresentation` |
| `WetoDesignTests` | `WetoDesign` | `DesignResources` bundle resolution, `MenuBarImageRenderer` |
| `WetoXPCTests` | `WetoXPC`, `WetoCore` | `UpdateService` |

`WetoHelper` and `WetoMenuBar` are executable targets with no test target: the helper's behaviour is root-only and the menu bar target is the `@main` entry point.

CI (`.github/workflows/pr-checks.yml`, runner `macos-26`, every PR and push to `master`) runs three steps: `swift build`, `swift test`, then **Packaging contracts** — `bash scripts/tests/build-artifact-contract.sh 9.9.9`, which does a real release build and therefore also runs `launch-agent-contract.sh` from inside `build.sh`. So both shell contracts below are gated on every PR, not only locally and on release. The step `chmod +x`s `build.sh`, `preinstall`, `postinstall` and both contract scripts before running them.

Both packaging failures the project has shipped so far ("the app never appeared" and "the popup crashed on click") were about packaging, which is why this step exists despite costing a full release build per PR.

### 2. Mocking rule of the project

Only system boundaries are substituted, and only through their protocols:
`GeoProbing`, `ProcessKilling`, `NetworkSnapshotReading`, `TargetResolving`, `NetworkEventSourcing`
(plus the adjacent `HTTPFetching`, `SecretStoring`, `ProcessLocating` in `Sources/WetoSystem/`).

Internal types are never substituted: `GuardPolicy`, `GuardController`, `ProcessEnforcer`, `ProcessMatcher` are exercised for real. This is what keeps the bulk of `WetoCoreTests` synchronous and double-free — `WetoCore` imports no system framework at all (project invariant, see `.claude/rules/ARCHITECTURE.md`). Test doubles live inline in the test file that needs them (`FakeFetcher` in `GeoProbeTests`, doubles in `GuardVMTests`, `UpdateVMTests`, `LaunchAgentControllerTests`); there is no shared mock/support target.

### 3. Launch agent contract

```bash
bash scripts/tests/launch-agent-contract.sh <payload-root>
# e.g. after a build:
bash scripts/tests/launch-agent-contract.sh .build/release_build/_pkg-root
```

Takes the PKG payload root as its only argument and is also invoked automatically by `scripts/build.sh` (line ~102) with the staged root, so a release build cannot be produced while the contract is red — which is also how it reaches CI (via the packaging-contracts step, which runs a real build).

What it asserts:

- `/Library/LaunchAgents` is absent/empty in the payload — the user agent must never be packaged system-wide.
- `Applications/Weto.app/Contents/MacOS/WetoMenuBar` exists and is executable.
- The update daemon *is* system-scoped: `Library/PrivilegedHelperTools/com.weto.helper` + `Library/LaunchDaemons/com.weto.helper.plist` with a matching MachService; `postinstall` bootstraps it into the system domain, `preinstall` and `Resources/uninstall-weto.sh` boot it out.
- Residency: `NSSupportsAutomaticTermination` and `NSSupportsSuddenTermination` are `false` in the built `Info.plist`, **and** `WetoMenuBarApp.swift` calls `disableAutomaticTermination` / `disableSuddenTermination`.
- `postinstall` resolves the console user's home via `NFSHomeDirectory`, writes into their `Library/LaunchAgents`, loads with `launchctl asuser … bootstrap`, does **not** verify startup via `pgrep`, and fails loudly when there is no GUI session.
- `preinstall` and the uninstaller remove both the user agent and the legacy system one, each with a `bootout` before deleting the plist.

### 4. Release artifact contract

```bash
bash scripts/tests/build-artifact-contract.sh            # defaults to version 9.9.9
bash scripts/tests/build-artifact-contract.sh 0.1.0
```

It performs a **real release build** (`scripts/build.sh`), so run it in a separate `git worktree` or repo copy rather than in the tree you are editing. CI runs exactly `… 9.9.9` as the "Packaging contracts" step, on a fresh checkout where that concern does not apply.

What it asserts:

- `md5` of `Sources/WetoCore/Constants.swift` and `Resources/Weto-Info.plist` is unchanged before/after the build — the release script must not touch tracked files, the version only lands in the staging copy of the plist.
- `.build/release_build/Weto-<version>.pkg` exists.
- `pkgutil --payload-files` contains no `docs/`.
- `CFBundleShortVersionString` inside the payload's `Weto.app/Contents/Info.plist` equals the requested version (not just the file name).

### 5. Why these cannot be unit tests

<!-- generated, verify -->

Every invariant above lives in artifacts that XCTest never sees: shell installer scripts (`preinstall`, `postinstall`, `Resources/uninstall-weto.sh`), the `pkgbuild` payload layout, and the generated `Info.plist`. A Swift process cannot observe how `installer` will lay out `/Library`, whether the staged plist got the version, or whether `postinstall` picked the console user's home instead of root's — and the failure mode of each is silent (app installed but never guarded, agent registered in the wrong domain, unsigned bundle). The contracts are grep-and-plist assertions on real build output, which is the only place that evidence exists.

## Common issues

- **`XCTSkip` in `WetoSystemTests`** — expected, not a failure: `NetworkEventSourceTests` skips when no running app exposes a bundle ID, `NetworkSnapshotReaderTests` skips when the machine has no network service literally named `Wi-Fi`. These read the live system, so results differ per machine.
- **Keychain/notification tests under `swift run` or bare `swift test`** — `Bundle.main` is the xctest runner, not the app bundle. `Constants.appVersion` therefore checks `CFBundleIdentifier` and returns `dev`, and `UpdateVM` takes the current version as a parameter. Don't "fix" a version mismatch by trusting `Bundle.main`.
- **`DesignResourcesTests` failing after moving resources** — resources must resolve through `DesignResources`, never `Bundle.module`; the generated `Bundle.module` only looks at the bundle root and the build machine's absolute path, and a resource bundle in the `.app` root makes `codesign` refuse to seal.
- **`build-artifact-contract.sh` reporting "сборка изменила отслеживаемые файлы версии"** — something in the release path is writing the version into tracked sources instead of the staging copy.
- **`launch-agent-contract.sh` failing with no payload** — the argument is mandatory; the script exits immediately if the payload root is not passed.
- **Size budget failure during `scripts/build.sh`** — not part of the contracts: `build.sh` itself rejects a `Weto.app` more than 10% above `APP_BASELINE_KB`. Usually means docs or assets leaked into the bundle.
- **A PR red on "Packaging contracts" but green on `swift test`** — the break is in the release path, not in Swift behaviour: every `build.sh` guard (resource bundle, ad-hoc signing, size budget, `<relocate>`) and the whole launch-agent contract now gate PRs. `runbooks/release.md` lists what each failure message means.

## Where logs / metrics

- `swift test` output only; no test reports are archived. Build products and the release artifact under `.build/` (`.build/app/Weto.app`, `.build/release_build/`).
- CI runs: GitHub Actions "PR Checks" workflow on `squaretus/weto`.
- Shell contracts print a single `✓`/`✗` line and exit non-zero on the first violation (`set -euo pipefail`).
