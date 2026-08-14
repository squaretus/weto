# Release

Cutting a weto version: a macOS PKG and two Linux tarballs, published as one GitHub
Release that feeds auto-update on both platforms.

## Steps

1. **Local `.app` (no PKG).** `macos/scripts/make-app.sh release` → `macos/.build/app/Weto.app`.
   Same layout as the PKG payload (`Contents/Resources`, nothing in the bundle root),
   version stays whatever `macos/Resources/Weto-Info.plist` carries (`0.1.0` today).
   Use `debug` (default arg) for a faster build. Bundle-only features (Keychain,
   notifications, `Constants.appVersion`) need the `.app`, not `swift run`.

2. **PKG locally.** `macos/scripts/build.sh <X.Y.Z>` → `macos/.build/release_build/Weto-<X.Y.Z>.pkg`.
   Builds `WetoMenuBar` + `WetoHelper` in release, stages `_pkg-root`
   (`Applications/Weto.app`, `Library/PrivilegedHelperTools/com.weto.helper`,
   `Library/LaunchDaemons/com.weto.helper.plist`), runs the safety net below,
   then `pkgbuild` → `productbuild`. Intermediates are deleted on success; only the
   `.pkg` remains.

3. **Version handling.** The version is written by `PlistBuddy` into the *staging copy*
   `_app/Weto.app/Contents/Info.plist` only. `macos/Resources/Weto-Info.plist` and
   `macos/Sources/WetoCore/Constants.swift` are never touched — a release must leave the work
   tree clean. `macos/scripts/tests/build-artifact-contract.sh [version]` asserts exactly that
   by comparing md5 of both files before/after a real build, and that the version landed
   in the bundle (not just in the file name).

4. **Release contract check (slow, and already gated).**
   `bash macos/scripts/tests/build-artifact-contract.sh 9.9.9` — does a full build, so locally run it
   in a separate worktree/copy. It is not called from `build.sh` (the reverse: it calls
   `build.sh`), but CI runs it on every PR and push to `master` as the "Packaging contracts" step
   of `pr-checks.yml`, which also drags in `launch-agent-contract.sh` and every `build.sh` guard
   below. A release therefore cannot be cut from a `master` that fails packaging.

5. **Publish.** Push a tag `vX.Y.Z` on `master`. `.github/workflows/release.yml`
   (runner `macos-26`) validates the tag matches `^[0-9]+\.[0-9]+\.[0-9]+$` after stripping
   `v`, runs `swift test`, runs `macos/scripts/build.sh "$VERSION"`, and publishes via
   `softprops/action-gh-release@v2` with `generate_release_notes: true`, attaching
   `macos/.build/release_build/Weto-<VERSION>.pkg`. Release name: `weto <VERSION>`.
   A mismatched tag fails the job before any build.

6. **Verify auto-update sees it.** The release must have the `.pkg` among its assets
   (see "Auto-update depends on the asset" below). `GET /repos/squaretus/weto/releases/latest`
   should return `tag_name` = the new tag and one asset ending in `.pkg`.

## Build safety net — and what each failure means

Every check below exists because the corresponding breakage already shipped once. All of them
run on every PR now (`pr-checks.yml` → "Packaging contracts"), not only when you cut a release.

- **`macos/Package.swift` declares `resources:` but no `.bundle` in `Contents/Resources`**
  → `✗ macos/Package.swift объявляет ресурсы, но в Contents/Resources нет ни одного .bundle`.
  SPM did not emit the resource bundle (renamed target, resources dropped from the manifest).
  Shipping anyway means no icons/flags at runtime, because `DesignResources` looks in
  `Contents/Resources` and `Bundle.module` is deliberately not used.

- **ad-hoc signing failed** → `✗ ad-hoc подпись Weto.app не удалась`.
  Signing is `codesign --force --sign - --deep`; a failure is never swallowed, because the
  output would be a broken bundle. Usual cause: something in the bundle root that `codesign`
  refuses to seal ("unsealed contents present in the bundle root").
  `make-app.sh` fails the same way.

- **`macos/scripts/tests/launch-agent-contract.sh "$ROOT"`** runs against the payload root before
  `pkgbuild`. It fails when: the payload contains a system agent
  `/Library/LaunchAgents/com.weto.app.plist` (or any non-empty `Library/LaunchAgents`);
  `Applications/Weto.app/Contents/MacOS/WetoMenuBar` is missing or non-executable;
  the update daemon or its LaunchDaemon plist is missing from the payload;
  `postinstall`/`preinstall`/`macos/Resources/uninstall-weto.sh` stopped agreeing on the agent path,
  `bootout`, `NFSHomeDirectory`, `launchctl asuser`, `bootstrap`, the system-domain daemon
  load/unload, or the "no GUI session" hard failure; `NSSupportsAutomaticTermination` /
  `NSSupportsSuddenTermination` in the bundle `Info.plist` are not `false`; or
  `WetoMenuBarApp.swift` lost `disableAutomaticTermination` / `disableSuddenTermination`.
  A failure here means the installed app would lose autostart or get put to sleep by the
  system right after install — the guard silently disappears.

- **Bundle size budget.** `APP_BASELINE_KB=2000`, hard limit +10% (2200 KB). Failure:
  `✗ бандл вырос больше чем на 10% от базового размера`. Something leaked into the payload
  (docs, images, a stray resource) — or the app genuinely grew, in which case bump
  `APP_BASELINE_KB` in `macos/scripts/build.sh` deliberately, do not raise the tolerance.

- **`<relocate>` in the expanded `PackageInfo`** → `✗ Weto.app помечен relocatable`.
  The component plist (`BundleIsRelocatable=false`, `BundleHasStrictIdentifier=true`,
  `RootRelativeBundlePath=Applications/Weto.app`) was lost or ignored. Without it Installer
  finds any bundle with id `com.weto.app` in LaunchServices — e.g. a dev build in
  `macos/.build/app` — and installs over *that* instead of `/Applications`. The LaunchAgent then
  points at nothing and launchd returns 78. `postinstall` also refuses to continue if
  `/Applications/Weto.app/Contents/MacOS/WetoMenuBar` is not executable.

- **Resource bundle missing from the packaged payload** → `✗ <name> отсутствует в
  Contents/Resources внутри пакета — иконок не будет`. Checked by grepping
  `pkgutil --payload-files` for `./Applications/Weto.app/Contents/Resources/<name>` — i.e.
  it survived staging but not `pkgbuild`.

`xattr -cr "$ROOT"` clears quarantine before packaging. Leftover `._*` entries in the archive
are `pkgbuild` metadata carriers for the non-clearable `com.apple.provenance`; they never
land on disk at install time. <!-- generated, verify -->

Installer UI comes from `macos/Resources/welcome.html` / `macos/Resources/conclusion.html` via the
generated `_distribution.xml`: `customize="never"`, `hostArchitectures="arm64"`,
minimum OS `26.0`. Editing installer copy means editing those two files.

## Linux artifacts

The release workflow builds Linux natively on two runners — `ubuntu-24.04` (x86_64) and
`ubuntu-24.04-arm` (aarch64); arm64 runners are free for public repositories, so there is
no QEMU and no cross-compilation anywhere. Each job produces
`weto-<X.Y.Z>-<arch>-linux.tar.zst` and uploads it under its own artifact name — a shared
name would let the second job overwrite the first and ship one archive instead of two.

Locally the same script does it: `linux/scripts/build.sh <X.Y.Z>`, which names the archive
from `uname -m`. It also guards the binary size, with **a separate baseline per
architecture** — the same code weighs noticeably differently on x86_64 and aarch64, and one
shared number would check one of them by accident. An unknown architecture fails the build
rather than skipping the check silently.

**Publication waits for all three jobs.** A half release would mean auto-update on the
other platform sees a release with no asset for it — and by contract such a release is not
a find at all, so the app would go quiet instead of updating.

**The app finds its own asset by suffix:** `ReleaseChecker` builds
`-{std::env::consts::ARCH}-linux.tar.zst`, which matches what `uname -m` produced on the
builder. Nothing hardcodes an architecture on either side; check both if either ever moves.

**Not verified on real arm64 hardware.** The artifact builds and its install contract
passes, but nobody has watched the tray or the windows on an arm64 desktop.

## Auto-update depends on the `.pkg` asset

`UpdateController` polls `https://api.github.com/repos/squaretus/weto/releases/latest`
every `UpdateFeedConfiguration.checkInterval` = 3600 s (1 h), and once at launch. `ReleaseParser.parse` strips a leading
`v` from `tag_name`, compares with `SemanticVersion`, and picks
`assets.first { name.hasSuffix(".pkg") }` as `downloadURL` — falling back to `""`.

Installation goes through the root daemon, and `UpdaterHelperProtocol.performUpdate` takes **no arguments**:
the daemon re-fetches the release itself, re-checks `isNewer`, re-reads the installed version
from `/Applications/Weto.app/Contents/Info.plist` (unreadable → the install is refused, not
attempted), and passes the asset URL through `ReleasePackageURL.isTrusted` — https only, host in
`github.com` / `objects.githubusercontent.com` / `release-assets.githubusercontent.com`,
path ending in `.pkg`.

A release without a `.pkg` asset (or with the package hosted elsewhere) yields
`downloadURL == ""`. The app does **not** ask the daemon in that case: `UpdateController.install`
shows "В релизе нет пакета — откройте страницу релиза" and opens the release page, so the
button never promises a one-click install it cannot deliver. (If the daemon were reached anyway
it would answer "В релизе нет файла .pkg".)

Practical consequences for a release:
- The asset name must end in `.pkg`; `Weto-<X.Y.Z>.pkg` from `build.sh` satisfies this.
- Exactly one `.pkg` per release — `first` wins, order is not guaranteed.
- The tag must be `vX.Y.Z` (or plain `X.Y.Z`); anything else makes
  `ReleaseParser` return `invalidVersion` and updates stop for every installed copy.
- Don't publish as draft/pre-release: `releases/latest` skips those. <!-- generated, verify -->
- The daemon downloads to `/var/db/weto/updates` (dir 0700, file 0600) and installs with
  `/usr/sbin/installer -pkg`. `preinstall` does `bootout system/com.weto.helper` and
  `killall WetoMenuBar`, which kills the very process doing the install — the progress window
  usually dies with it. That is expected, not a failed update. The app's launch agent has
  `KeepAlive`, so launchd starts the new version right after.
- The download progress *is* visible: the daemon keeps phase and fraction in memory and the app
  polls `installState` every 0.4 s while the install is in flight, rendering it in the update
  window and in the popup banner. A failed download or `installer` run arrives the same way, as
  the `failed` phase. The record is not persisted, so if the daemon respawns before the next poll
  the only remaining evidence is `log show --predicate 'subsystem == "com.weto.helper"'`.

## Signing: ad-hoc only, on purpose

No Developer ID, no notarization (no paid Apple Developer account) — a deliberate, documented
trade-off (README, "Установка"). Consequences to keep in mind and to keep in the README:

- Gatekeeper blocks the downloaded `.pkg` on first open. The user must go to
  System Settings → Privacy & Security → Security and press "Открыть все равно"
  ("Open Anyway"), then authenticate.
- The daemon authorizes its XPC client **by executable path**, not by team id: with no
  Developer ID there is nothing for `SecCodeCheckValidity` to match. This does not protect
  against root; the limit is accepted knowingly.
- Do not add signing identities to `build.sh` ad hoc — changing this is an architecture
  decision, not a build tweak.

## Common issues

- **`swift test` red in the release workflow** — the tag is already pushed but no release
  exists. Fix on `master`, then move/re-push the tag; the workflow only triggers on `push` of
  `v*` tags. Note branches are never deleted in this project. <!-- generated, verify -->
- **Dirty work tree after a local build** — should be impossible; if it happens,
  `build-artifact-contract.sh` will name it, and the culprit is a new `PlistBuddy`/`sed` call
  writing to a tracked file instead of the staging copy.
- **Installer succeeds but no menu bar icon** — usually the relocatable/`BundleIsRelocatable`
  class of bug, or the app was installed over a dev bundle registered in LaunchServices;
  `postinstall` should have failed loudly.
- **"Не найден пользователь графического сеанса"** — installing over SSH / at the login
  window. `postinstall` needs a console user to write and bootstrap the user agent.
- **Bundle version reads `dev` at runtime** — `Constants.appVersion` verifies
  `CFBundleIdentifier` and returns `dev` otherwise (tests, `swift run`). Expected outside
  the `.app`; inside a packaged build it means the plist copy or `PlistBuddy` step broke.

## Where logs / metrics

- CI: GitHub Actions → workflows `Release` (tags `v*`) and `PR Checks` (`master` PRs/pushes).
- Local build output: `macos/.build/release_build/` (`Weto-<version>.pkg`), `macos/.build/app/Weto.app`.
- Update daemon: `HelperLogger` (`macos/Packages/UpdateKit/Sources/UpdateKitHelper/HelperLogger.swift`);
  working directory `/var/db/weto`. The install phase and the last failure are additionally
  readable from the app itself (update window → progress or error text, via `installState`)
  while the daemon lives.
- In-app journal: popup / Settings → Journal card (ring buffer of 10 entries in
  `UserDefaults(suiteName: "com.weto.shared")`).
- Full removal for a clean re-test: `macos/Resources/uninstall-weto.sh` (also shipped inside the
  app at `Contents/Resources/uninstall-weto.sh`) — drops the agent, daemon, `/var/db/weto`,
  the app, prefs, caches, the Keychain item, and `pkgutil --forget com.weto.pkg`.
