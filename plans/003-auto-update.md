# Plan 003: Auto-update via Sparkle

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm its expected result before proceeding. If
> anything in "STOP conditions" occurs, stop and report — do not improvise.
> Update your row in `plans/README.md` when done unless a reviewer said they
> mind it.
>
> **Drift check (run first)**: `git diff --stat b3a29ef..HEAD -- Package.swift Sources/BantayTUI`
> The files in scope are `Package.swift`, `Sources/BantayTUI/DynamicIslandApp.swift`,
> `Sources/BantayTUI/SettingsView.swift` (may not exist yet if 002 hasn't landed);
> if their shape differs from the excerpts, reconcile before proceeding.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: 002 (to host "Check for Updates…"/update prefs), and on
  signing/notarization work (see "Prerequisites" — do NOT ship auto-update to
  users from a dev-machine build).
- **Category**: direction
- **Planned at**: commit `b3a29ef`, 2026-08-02
- **Issue**: none

## Why this matters

Users currently have no way to learn a new version exists. A notch app that
breaks daily without an update path is a chunky drain: it silently sits in the
menu bar and eventually gets quit — and thanks to `KeepAlive` even quit doesn't
remove it — so updating matters both for the feature and for the "this is a
real product" signal. BoringNotch's answer is Sparkle (in-app
"Check for Updates…" + auto-check/auto-download toggles, see the study in
`000-ux-research.md` §5). We mirror that.

## Prerequisites (do not skip)

- The release binary must be **Developer ID–signed and notarized** before a
  Sparkle auto-update is meaningful. This repo is currently ad-hoc signed only
  (README, DEVELOPMENT_PLAN Phase 5.1). Publishing a Sparkle `appcast.xml` +
  signed DMG is out of scope for *this* plan; this plan only adds the
  mechanism (feed URL abstracted, `SPUUpdater` wired, prefs surfaced) so that
  when signing lands, the only new step is a release script that uploads the
  artifact and updates `appcast.xml`.
- Apple doesn't SMS; I'm saying: don't wire the feed to a placeholder 404. Use
  a GitHub Releases feed hosted at  `https://github.com/8-BitRhyon/bantay-tui/releases/latest/download/appcast.xml` and
  keep the update disabled (`automaticallyChecksForUpdates` default false)
  until the first signed release exists; ship the *button* regardless.

## 1. Commands

| Purpose | Command | Expected on success |
|---|---|---|
| Format lint | `swift format lint --recursive --strict Sources Tests` | exit 0 |
| Build | `swift build` | exit 0, no warnings |
| Release | `swift build -c release` | exit 0 |

## 2. Scope

**In scope**:
- `Package.swift` — add `Sparkle` binary package (see Step 1).
- `Sources/BantayTUI/DynamicIslandApp.swift` — init updater, add
  "Check for Updates…" menu item.
- `Sources/BantayTUI/SettingsView.swift` (from 002, may not exist) — "Updates" section.

**Out of scope**:
- Signing/notarization pipeline, DMG, appcast generation script — those are a
  separate release-engineering plan (DEVELOPMENT_PLAN Phase 5.1–5.3); this plan
  only frontends Sparkle.
- Homebrew cask.

## 3. Conventions

- Match `NotchHUDConfig` persistence pattern for the two new prefs
  (`automaticallyChecksForUpdates`, `automaticallyDownloadsUpdates`).
- Menu pattern: match `menuNeedsUpdate` style items (target/action pattern
  after `togglePolling`).
- No comments unless needed; code should self-document.

## 4. Steps

### Step 1: Add Sparkle

`Package.swift` binary target (pinned URL + exactExport constant):

```swift
dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle",
             from: "2.6.4"),
]
...
.executableTarget(
    name: "BantayTUI",
    path: "Sources/BantayTUI",
    linkerSettings: [
        .linkedFramework("Sparkle"),
    ],
    resources: []),
```

Sparkle is delivered as a **binary target** (`Sparkle` xcframework). The
package manifest for a binary dependency uses `.binaryTarget(path:)`? No —
Sparkle ships a standard SwiftPM package URL (via its own `Package.swift`
declaring a binary framework target). `swift package resolve` will fetch it.
Pin the exact version; CLI-only every audit has flagged the binary blob —
best to also add the `.binaryTarget` check to `.github/workflows` pins layer
later, out of scope here.

**Verify**: `swift build` + `swift build -c release` → 0

### Step 2: Start the updater in the app

Add to `AppDelegate` (+ `@State` in `DynamicIslandApp` if SwiftUI)

```swift
import Sparkle

let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
// retain a strong ref; start auto-check from config

func applicationDidFinishLaunching(...) {
    ...
    if NotchHUDConfig.shared.automaticallyChecksForUpdates {
        updaterController.updater.start()
    }
}
```

### Step 3: Menu & settings surface

Add menu item in `menuNeedsUpdate` next to Quit:

```swift
let checkItem = NSMenuItem(title: "Check for Updates…",
                           action: #selector(checkForUpdates), keyEquivalent: "")
checkItem.target = self
```

Handler: `updaterController.updater.checkForUpdates(in: nil)`

In `SettingsView` add "Updates" section mirroring `SoftwareUpdater.swift`
toggle "Automatically check" and the "Check for Updates…" button.

### Step 4: appcast placeholder

Create `update/appcast.xml` with a stub (zero items) and a
`<link>https://github.com/8-BitRhyon/bantay-tui/releases/latest</link>` —
documented, and later the release pipeline overwrites it with signed item
entries. Feed URL in code = a constant `DSUAppCastURL`.

### 5. Verify

- `swift build`/`swift build -c release` 0
- `swift format lint` 0
- Manual (real Mac): menu item exists; "Check for Updates…" opens Sparkle's
  modal; with no appcast rows it says "You're up-to-date".

## Test plan (thin)

- Sparkle is Apple-composable; no unit tests here. Add a pure helper test if a
  feed-URL builder is introduced (pattern: existing TESTs pure only).
- Manual matrix recorded in Done criteria below.

## 6. Done criteria

- [ ] `Package.swift` Sparkle dep resolves, both build configs pass
- [ ] Menu "Check for Updates…" triggers Sparkle UI on a real Mac
- [ ] Settings "Updates" section toggles persist (`NotchHUDConfig`)
- [ ] Feed URL constant points at the placeholder appcast
- [ ] no warnings, `swift format lint` 0
- [ ] OUT of scope respected; only the three files touched
- [ ] README row (plans/README.md) updated

## 7. STOP conditions

- If Sparkle SPM resolution fails on CLT (no Xcode URL session) — that's
  expected; build gates still pass, but note it. Sparkle requires macOS app
  framework linkage, which is genuine here (it's an app). Report anything else.
- If `sparkleproject default` `automaticallyChecksForUpdates` must be read from
  config, don't set it wrongly (false default until first signed release).
- If CI's Layer 5 complains about unpinned package, stop — that's a workflow
  change requiring the owner's input (add SHA pin to `Package.resolved`).

## 8. Maintenance notes

- The release pipeline later must (a) `codesign` with Developer ID,
  (b) `notarytool`+staple, (c) generate `appendix.xml` via
  `sparkle: generate_appcast`, (d) upload DMG+appcast to a CDN/GH Release,
  (e) flip `automaticallyDownloadsUpdates` on. That is a separate plan.
- Sparkle's default UI window is fine; don't stub a custom driver unless
  needed.