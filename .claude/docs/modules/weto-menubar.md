# WetoMenuBar

## Purpose
Executable target and the only UI surface of the app: the menu bar item with its status
popup, and the settings window (two tabs: settings, journal). It owns process lifecycle
concerns that cannot live in a library — the `@main` entry point, `AppDelegate`,
single-instance guard, residency declarations — and delegates every decision to
`AppCoordinator` from `WetoShared`. Views hold draft input and local error text only;
parsing, validation and persistence happen in the stores.

## Key files
- `macos/Sources/WetoMenuBar/WetoMenuBarApp.swift` — `@main` scene, `AppDelegate`, `SingleInstanceGuard`
- `macos/Sources/WetoMenuBar/MenuBarLabel.swift`
- `macos/Sources/WetoMenuBar/StatusPopupView.swift`
- `macos/Sources/WetoMenuBar/JournalRow.swift`
- `macos/Sources/WetoMenuBar/Settings/SettingsWindow.swift`
- `macos/Sources/WetoMenuBar/Settings/TargetsCard.swift`
- `macos/Sources/WetoMenuBar/Settings/NetworkSettingsCard.swift`
- `macos/Sources/WetoMenuBar/Settings/BlacklistCard.swift`
- `macos/Sources/WetoMenuBar/Settings/MaintenanceCard.swift`
- `macos/Sources/WetoMenuBar/Settings/JournalCard.swift`
- `macos/Sources/WetoMenuBar/Settings/SettingsFooter.swift`
- `macos/Resources/Weto-Info.plist` — bundle identity plus residency flags (copied by `macos/scripts/make-app.sh`)

## Entry points
- `WetoMenuBarApp` (`@main`) → `MenuBarExtra` with `.menuBarExtraStyle(.window)` +
  `Window(id: SettingsWindow.identifier /* "settings" */)`
- `AppDelegate.applicationDidFinishLaunching` → acquires singleton port, sets `.accessory`
  activation policy, disables automatic/sudden termination, `coordinator.start()`
- `AppDelegate.applicationWillTerminate` → `coordinator.stopForTermination()`
- `AppDelegate.coordinator: AppCoordinator` — injected into both scenes via `.environment(...)`
- `SettingsWindow.identifier` — the only string shared with `StatusPopupView`'s gear button
  (`openWindow(id:)` + `NSApplication.shared.activate`)

## Dependencies
- Package targets: `WetoShared` (`AppCoordinator`, `GuardVM`, `SettingsStore`, `EventLogStore`,
  `UpdateController` (from `UpdateKit`), `LaunchAgentManaging`, `Maintenance`, `StatusPresentation`), `WetoDesign`
  (`WetoTokens`, `WetoCard/Row/Panel/Divider`, `WetoSegmentedControl`, `WetoBanner`,
  button/field styles, `StatusShield`, `MenuBarImageRenderer`, `TargetIconStore`),
  `WetoCore` (`KillEvent`, `GuardStatusColor`, `Constants`, `AppTheme`), `WetoSystem`
  (`FlagImageStore` only)
- Frameworks: SwiftUI, AppKit (`NSAlert`, `NSOpenPanel`, `NSWorkspace`, `NSApplication`,
  `NSViewRepresentable`), CoreFoundation (`CFMessagePortCreateLocal`)
- No test target: `macos/Tests/` has no `WetoMenuBarTests`

## Side effects
<!-- generated, verify -->
- Creates a Mach message port `com.weto.app.singleton`; failure to create it terminates
  the process immediately (second copy loses)
- Holds an `NSObjectProtocol` activity token for the whole process lifetime
  (`beginActivity(.userInitiatedAllowingIdleSystemSleep)`) — App Nap would otherwise coalesce
  the guard's one-second timers into minutes, and a windowless `LSUIElement` app is exactly its
  target profile. Releasing the token brings the throttling back
- Mutates persisted state through stores on user input: `settings.targets`,
  `settings.vpnAppRule`, `settings.appTheme`,
  `settings.addBlockedEntry` / `removeBlockedEntry`, `settings.setIPInfoToken`
  (Keychain write), `eventLog.clear()`
- `MaintenanceCard` writes/removes `~/Library/LaunchAgents/com.weto.app.plist` via
  `launchAgent.enable()`/`disable()`, runs `maintenance.closeApp()` / `uninstall()` and
  calls `NSApplication.shared.terminate` on success
- `SettingsFooter` / status popup banner trigger `update.primaryAction()` and
  `update.installUpdate()` — network check and privileged install via the helper daemon
- `SettingsFooter` opens `Constants.githubRepoURL` in the default browser
- `TargetsCard.pickFromDisk` opens a modal `NSOpenPanel` rooted at `/Applications`
- `onAppear` hooks re-read system state: `guardVM.refreshRunningTargets()` (popup and
  window), `guardVM.refreshVPNCandidates()` (window)
- Reads flag SVGs through `FlagImageStore.shared` and app icons through
  `TargetIconStore.shared` while rendering

## Invariants / assumptions
<!-- generated, verify -->
- **Guard start belongs to `AppDelegate.applicationDidFinishLaunching`, never to `.task`
  on the popup content.** With `.menuBarExtraStyle(.window)` SwiftUI builds the popup
  lazily, so protection would not exist until the user first opened the menu.
- **Residency is declared explicitly.** `NSSupportsAutomaticTermination` and
  `NSSupportsSuddenTermination` are `false` in `Weto-Info.plist`, and the delegate also
  calls `ProcessInfo.disableAutomaticTermination` / `disableSuddenTermination`. The copy
  launched by launchd is flagged idle by macOS and gets killed silently in the moment it
  has no window — popup closed, settings window not yet created.
- **`NSAlert`, not SwiftUI `.alert`.** In an app with `MenuBarExtra` the SwiftUI alert
  dismisses the popover, so confirmations are `runModal()`.
- **Side effects hang off binding setters, not `onChange`.** `MaintenanceCard.onAppear`
  syncs the launch-at-login toggle with the system; `onChange` read that sync as a tap and
  re-registered the agent, meaning the app booted itself out of launchd and vanished
  together with the guard. Same rule for the theme, VPN picker and poll interval bindings.
- **Toggle state comes back from the system, not from the tap.** `setLaunchAtLogin` re-reads
  `launchAgent.isInstalled` after acting and shows `failureValue?.displayText`.
- **In a `Form`/label-column context a `TextField` first argument breaks row layout.**
  Placeholders are passed via `prompt:` plus `.labelsHidden()` everywhere.
- Only one copy is meaningful: activation policy is `.accessory` and `LSUIElement` is true,
  so there is no Dock icon and no window at launch.
- The module carries no domain logic and therefore no tests — anything worth testing must
  be pushed down into `WetoShared`/`WetoCore`.
- VPN picker tags carry the service **UUID**, never the name: two services can share a name.
- The ipinfo token is never displayed in full unless the field is focused; `maskedToken`
  is compared against the draft to avoid saving the mask itself.

- **The app reaches the Dock only when it owns a window.** It is an accessory by default
  (`LSUIElement` plus `.accessory`), but the settings and update windows are ordinary
  windows, and without a Dock icon they cannot be found in Cmd+Tab or with the mouse.
  `DockPresence` watches windows appear and close and flips the activation policy. The menu
  bar popup does not count as a window (not titled, cannot become main) — otherwise the icon
  would blink every time the menu opens.

## Failure hotspots
<!-- generated, verify -->
- Any new `onChange`/`onAppear` pair on synchronized state — the launchd self-boot-out class
  of bug (app disappears with no crash report, `runs` counter in the hundreds)
- New SwiftUI `.alert`/`.confirmationDialog` inside the popup: silently closes the popover
- Adding a `.task`/`.onAppear` that starts long-lived work in popup content: runs lazily,
  or repeatedly on every popup open
- `SettingsWindowConfigurator` reaches `view.window` through `DispatchQueue.main.async`;
  timing changes in SwiftUI window creation can leave the titlebar unconfigured
- `ForEach` over `settings.targets` / `blockedEntries` uses `id: \.element` — duplicate
  entries would collide, which is why `add()` refuses duplicates
- `uninstall()` partial failure path: terminating without showing `failureText` would leave
  files on disk while the user believes the system is clean
- Resource loading must go through `DesignResources`; `Bundle.module` lookups from this
  target break the signed `.app` layout

## Related docs
- `.claude/rules/ARCHITECTURE.md` — module index and key contracts
- `docs/design-system.md` — visual language the cards and popup must follow
- `.claude/docs/debug-map.md`
