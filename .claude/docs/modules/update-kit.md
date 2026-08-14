# UpdateKit (portable update mechanism)

## Purpose
The whole update mechanism — hourly check, decision to show, the dialog, deferral, and the
root install with live progress — packaged as a separate SPM package under `macos/Packages/UpdateKit`
so it can be moved to another project by copying the folder. The package knows no constant of
any concrete application: repository, mach service name, install paths, defaults suite and
intervals all arrive in `UpdateFeedConfiguration`. weto's glue is three places:
`macos/Sources/WetoCore/WetoUpdate.swift` (the configuration value),
`macos/Sources/WetoShared/WetoUpdateTheme.swift` (colors, fonts, button builders) and
`macos/Sources/WetoHelper/main.swift` (the daemon entry point).

Five targets, split along linking boundaries: the root daemon links Core + XPC + Helper and
never pulls SwiftUI; the app links Core + XPC + UpdateKit + UpdateKitUI and never pulls the
root logic.

## Key files
- `macos/Packages/UpdateKit/Package.swift`
- `macos/Packages/UpdateKit/Sources/UpdateKitCore/UpdateFeedConfiguration.swift`
- `macos/Packages/UpdateKit/Sources/UpdateKitCore/UpdatePolicy.swift`, `UpdateDeferral.swift`
- `macos/Packages/UpdateKit/Sources/UpdateKitCore/UpdateProgress.swift`
- `macos/Packages/UpdateKit/Sources/UpdateKitCore/UpdateDialogModel.swift`, `UpdateStrings.swift`
- `macos/Packages/UpdateKit/Sources/UpdateKitCore/SemanticVersion.swift` (versions, `UpdateInfo`, `ReleaseParser`)
- `macos/Packages/UpdateKit/Sources/UpdateKitCore/ReleasePackageURL.swift` (download host allowlist)
- `macos/Packages/UpdateKit/Sources/UpdateKitXPC/UpdaterHelperProtocol.swift`, `UpdaterXPCClient.swift`, `UpdaterService.swift`
- `macos/Packages/UpdateKit/Sources/UpdateKit/UpdateController.swift`, `UpdateBoundaries.swift`
- `macos/Packages/UpdateKit/Sources/UpdateKit/UserDefaultsUpdateStore.swift`, `URLSessionReleaseFetcher.swift`, `HelperUpdateInstaller.swift`
- `macos/Packages/UpdateKit/Sources/UpdateKitUI/UpdateTheme.swift`, `UpdateDialogView.swift`, `UpdateWindowPresenter.swift`
- `macos/Packages/UpdateKit/Sources/UpdateKitHelper/UpdaterHelperService.swift`, `HelperUpdateFlow.swift`, `HelperInstallState.swift`, `PackageDownloader.swift`, `ReleaseChecker.swift`, `ClientAuthorization.swift`
- `macos/Packages/UpdateKit/Tests/…` — run with `swift test --package-path macos/Packages/UpdateKit`

## Entry points
- `UpdateController.start()` — one immediate check plus the hourly loop; starting twice does
  not create a second loop.
- `UpdateController.checkNow()` — manual check; ignores skip and reminder and always shows
  the dialog. The only way back to a skipped version.
- `UpdateController.install()` / `skipCurrentVersion()` / `remindLater(_:)` / `dismissDialog()`
  — dismiss equals "remind in 3 hours"; silently closing a window must not mean "never again".
- `UpdateController.isAutoInstallEnabled` — the same setting behind the dialog checkbox and
  the settings toggle; turning it on with an update pending starts the install immediately.
- `UpdateController.availableUpdate` / `bannerUpdate` / `dialogModel` / `progress` — what UI reads.
  `bannerUpdate` is `nil` while the policy verdict is `silent`, so a skipped or deferred version
  hides the banner too.
- `UpdatePolicy.decide(latest:deferral:now:) → .silent | .prompt | .install` — the only place
  that decides. Pure function, tested synchronously.
- `UpdaterHelperService(configuration:)` — daemon side: `NSXPCListenerDelegate` plus the three
  protocol methods.

## Boundaries (the only things tests substitute)
`ReleaseFetching`, `UpdateInstalling`, `UpdateStateStoring`, `UpdateClock`, `URLOpening`.
`SystemURLOpener` lives in weto, not in the package: `UpdateKit` must not link AppKit.

## Gotchas
- **`UpdateKitCore` imports no system frameworks and performs no I/O** — same invariant as
  `WetoCore`, same reason: the bulk of the tests stays synchronous and mock-free.
- **`UpdateKitXPC` has no dependencies at all.** The XPC boundary carries numbers and strings;
  mapping the `(Int, Double, String?)` triple into `UpdateProgress` is Core's job.
- **An unknown phase code reads as `.installing`, never as `.idle`.** An older daemon that
  predates `installState` must not look like a finished install.
- **Silence from the daemon is neither success nor failure** — the controller keeps the
  progress up instead of pretending the install ended.
- **The reminder is stored as an absolute date** and capped at six hours ahead: moving the
  system clock backwards would otherwise lock updates away for an arbitrary time.
- **Auto-install runs with no dialog** and relies on the app's launch agent having
  `KeepAlive`: the installer terminates the app and launchd brings it back.
- **The install fraction is only meaningful while downloading.** `installer` reports no
  progress, so the installing phase is honestly indeterminate.
- **The daemon never receives a URL or a version from the client** — it re-checks the release
  itself. Otherwise any authorized process could ask root to install an arbitrary package.
