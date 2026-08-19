# WetoDesign

## Purpose
Design system of the app: colour/spacing/type tokens plus the SwiftUI components and
AppKit image renderers built on them. It is the only target that owns visual language, so
`WetoMenuBar` never spells out a colour, radius or font by hand. The canonical spec lives in
`docs/design-system.md`; this target is its executable form. Components know nothing about
application state — they take values and closures, never view models.

## Key files
- `macos/Sources/WetoDesign/Tokens/WetoTokens.swift` — `Color(hex:)`, `WetoColor`, `WetoTokens`, `StatusTone`
- `macos/Sources/WetoDesign/Components/WetoCard.swift` — `WetoCard`, `WetoRow`, `WetoDivider`, `WetoPanel`
- `macos/Sources/WetoDesign/Components/WetoControls.swift` — segmented control, button/field styles, `WetoMenuButton`, `StatusShield`
- `macos/Sources/WetoDesign/Components/WetoBanner.swift`
- `macos/Sources/WetoDesign/Components/WetoProcessPill.swift`
- `macos/Sources/WetoDesign/Components/WetoDeleteRowAction.swift`
- `macos/Sources/WetoDesign/Components/MenuBarImageRenderer.swift`
- `macos/Sources/WetoDesign/TargetIconStore.swift`
- `macos/Sources/WetoDesign/DesignResources.swift`
- `macos/Sources/WetoDesign/Resources/cli-claude.svg`, `macos/Sources/WetoDesign/Resources/cli-codex.png`
- Tests: `macos/Tests/WetoDesignTests/DesignResourcesTests.swift`, `MenuBarImageRendererTests.swift`

## Entry points
- `WetoTokens.<token>` — palette (`shell`/`card`/`sunk`/`line`/`sunkLine`/`ink`/`dim`/`faint`/
  `violet`/`green`/`amber`/`red`/shadows), spacing `space1…space5`, radii, window sizes, fonts
- `WetoColor.resolve(_ scheme: ColorScheme) → Color`
- `StatusTone.color → WetoColor` (`.ok`/`.degraded`/`.blocked`/`.off`)
- `WetoPanel(width:content:)`, `WetoCard(_ caption:content:)`, `WetoRow(content:)`, `WetoDivider()`
- `WetoSegmentedControl(selection:options:)` — generic over `Value: Hashable`
- `WetoPillButtonStyle(_ kind: .primary/.ghost/.danger, expands:)`, `WetoTileButtonStyle()`,
  `WetoIconButtonStyle()`, `WetoFieldStyle()`, `WetoMenuButton(_ title:items:)`
- `StatusShield(tone:)`, `WetoBanner(tone:systemImage:text:trailing:)`,
  `WetoProcessPill(icon:title:isCommandLine:childCount:)`,
  `WetoDeleteRowAction(label:hint:action:)`
- `MenuBarImageRenderer.image(flagImage:color:) → NSImage` — no country code: nothing draws it
- `TargetIconStore.shared.icon(for: TargetIconKind, size:) → NSImage?`
- `DesignResources.bundle`, `DesignResources.url(forResource:) → URL?`

## Dependencies
- SPM target dependencies: **none**. Declared as `.target(name: "WetoDesign", resources: [.process("Resources")])`
  — it does not link `WetoCore`, so `StatusTone` is a design-side enum, not a domain type.
- Frameworks: SwiftUI, AppKit (`NSImage`, `NSBezierPath`, `NSWorkspace`, `NSGraphicsContext`)
- Bundled resources: `weto_WetoDesign.bundle` (brand CLI icons)
- System: `NSWorkspace.shared.icon(forFile:)` for `.app` bundles and for the Terminal fallback
  (`/System/Applications/Utilities/Terminal.app`)
- Consumers: `macos/Sources/WetoMenuBar/**` only (`MenuBarLabel`, `StatusPopupView`, `Settings/*`,
  `JournalRow`)

## Side effects
<!-- generated, verify -->
- Filesystem reads: `DesignResources` probes up to four bundle locations on first access;
  brand art read via `NSImage(contentsOf:)`; `NSWorkspace` reads icons of arbitrary target paths.
- In-memory caches (no disk, no DB, no network):
  - `MenuBarImageRenderer.cache` — up to 32 entries, guarded by `NSLock`, FIFO eviction via
    a parallel `order` array (not LRU: cache hits do not refresh position). The key is
    `CacheKey { flag: NSImage?, color: ColorKey }`, so an entry keeps its flag `NSImage` alive
    for as long as it stays in the cache.
  - `TargetIconStore.cache` — **unbounded**, `@MainActor`-confined, keyed by
    `"\(kind)|\(size)"`, grows with the number of distinct target paths × icon sizes.
- Off-screen rasterisation: every renderer builds `NSImage(size:flipped:)` draw blocks;
  `MenuBarImageRenderer` temporarily switches the graphics context to `.destinationOut`
  to punch a transparent gap around the status dot, then restores `.sourceOver`.
- No network. Country flags are fetched elsewhere (`WetoSystem/FlagImageStore`) and handed in
  as an already-decoded `NSImage`.

## Invariants / assumptions
<!-- generated, verify -->
- **Resources are reached only through `DesignResources`, never `Bundle.module`.** The generated
  SPM accessor looks only at the root of `Bundle.main` and at the build machine's absolute path.
  In the app that means a bundle copy in the root of `Weto.app`, and `codesign` refuses to seal
  that layout ("unsealed contents present in the bundle root") — the signature was silently not
  produced. Resources therefore live in `Contents/Resources`; both `macos/scripts/make-app.sh` and
  `macos/scripts/build.sh` copy `*.bundle` there, and `build.sh` fails the build if `macos/Package.swift`
  declares resources but no `.bundle` landed in `Contents/Resources` (and again if it is missing
  from the assembled PKG payload).
- `DesignResources.bundle` probe order is `Bundle.main.resourceURL` → `Bundle.main.bundleURL` →
  the same two for `Bundle(for: BundleToken.self)` → `.module`. The `.module` fallback exists for
  `swift test` and `swift run`, where `Bundle.main` is a foreign bundle (the xctest runner).
- `DesignResources.url(forResource:)` accepts both an exact filename (`"cli-codex.png"`) and an
  extension-less image name (`"cli-codex"`, resolved by `urlForImageResource`). `TargetIconStore`
  relies on the second form, the tests cover the first.
- Components are stateless and state-agnostic: colour comes from `@Environment(\.colorScheme)`
  through `WetoColor.resolve`, everything else from init parameters. No `@Observable` type is
  imported here, so the module cannot depend on app state even by accident.
- Every colour must be declared as a `WetoColor` pair (dark + light); a bare `Color` in a
  component means the light theme was not considered.
- **Every control that can share a row is exactly `WetoTokens.controlHeight` tall.** The pill
  button, the text field and `WetoMenuButton` set `.frame(height:)`; none of them derives its
  height from font metrics plus vertical padding. That derivation is what tilted the update
  window's action row: labels of different length and with different descenders produced
  different heights, and `Menu` styled `.borderlessButton` had no pill at all — AppKit drew
  bare text with its own indicator, half a line off the buttons beside it. A row that mixes
  pills with `WetoMenuButton` also states `HStack(alignment: .center)` explicitly.
- **`MenuBarImageRenderer`'s cache key is the drawn input itself, never a stand-in for it.**
  The flag is keyed by its `NSImage` (default `NSObject` identity, and the key holds a strong
  reference so a freed image's address cannot be reused), and the colour by rounded sRGB
  components ×1000 — not by `NSColor.description`, which is undocumented identity that differs
  per colour space. A colour with no sRGB representation (`usingColorSpace(.sRGB) == nil`) is
  rendered every time and not cached at all: better an extra render than someone else's image
  under a doubtful key. Pinned by `test_new_flag_bitmap_for_the_same_country_is_re_rendered`
  and `test_same_color_in_another_color_space_hits_the_cache`.
- `MenuBarImageRenderer` output has `isTemplate = false` on purpose — the flag must keep its own
  colours and the status dot its tone, so macOS must not tint the image.
- Menu bar canvas is fixed at 22×22 pt (menu bar height); the status dot sits at −45° on the
  flag ring.

- **The app icon follows the theme** (`WetoAppIcon` + `AppCoordinator.applyAppIcon`): the
  Dock, `NSAlert` and the update window all show it. The bundle ships a static `AppIcon.icns`;
  both images and the `.icns` are generated from `shared/icon/*.icon` by
  `macos/scripts/build-icon.sh`, so editing the PNGs by hand is pointless — they are output.

## Failure hotspots
<!-- generated, verify -->
- **Resource lookup.** Any new `Bundle.module` call site works in `swift test` and breaks in the
  shipped `.app`, or worse, breaks the signature. Same class of bug if a build script stops
  copying `*.bundle` into `Contents/Resources`.
- **`MenuBarImageRenderer` cache retention.** The key now holds the flag `NSImage` itself, so up
  to 32 flag bitmaps stay alive as long as they sit in the cache, and FIFO eviction means a
  frequently used flag can still be pushed out by 32 newer combinations. The previous key
  (`"<none|countryCode>|\(color.description)"`) had the opposite failure: a fresh bitmap for an
  already-cached country code returned the stale image, and the same colour built in another
  colour space missed the cache.
- **`TargetIconStore` staleness and growth.** Icons are cached forever: replacing a target `.app`
  (or its icon) shows the old icon until relaunch, and a long-lived process accumulating many
  targets never releases entries.
- **Token drift from the spec.** Numbers duplicated between `docs/design-system.md` and
  `WetoTokens` can diverge; also `StatusShield` hardcodes `cornerRadius: 11` instead of
  `WetoTokens.radiusPill`, so a radius change to the token misses the shield.
- **A new control that skips `controlHeight`.** Anything added with vertical padding instead of
  the token looks right on its own and tilts the first row it lands in. `WetoUpdateThemeTests`
  measures the update row through `NSHostingView`; the equivalent Linux check is
  `linux/crates/weto-ui/tests/controls.rs`.
- **User-facing text inside the design layer.** `WetoProcessPill` carries the literal
  `"terminal"` and a Russian accessibility label — copy changes have to be made here, not in
  `WetoMenuBar`, which is easy to miss.
- **Pixel-level tests.** `MenuBarImageRendererTests` samples concrete pixels and flips Y
  (`colorAt` counts from the top, `NSImage` from the bottom); geometry tweaks break them by
  design — recompute the expected coordinates rather than loosen the assertions.

## Related docs
- `docs/design-system.md` — canonical visual language (not under `.claude/docs/`)
- `.claude/rules/ARCHITECTURE.md` — module index and the resources/`codesign` contract
