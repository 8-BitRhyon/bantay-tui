# Plan 002: Real Settings window + onboarding

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report  -  do not improvise. When done, update the status row for this plan
> in `plans/README.md` unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat b3a29ef..HEAD -- Sources/BantayTUI`
> In scope state are `DynamicIslandApp.swift` + `NotchHUDConfig.swift`; if those
> changed since this plan, compare excerpts and treat any mismatch as a STOP.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: 001 (the `islandEnabled`/`snoozedUntil` keys + `notchVisibilityChanged` notification it adds)
- **Category**: direction
- **Planned at**: commit `b3a29ef`, 2026-08-02
- **Issue**: none

## Why this matters

`Settings { EmptyView() }` is the single most visible "unfinished" signal in
the app: Cmd+, opens a blank window while `NotchHUDConfig` already holds six
useful settings with no UI. There is no "Open at login" toggle, no onboarding
that explains install/hook steps, and no way to test a sound. Giving the app a
proper preferences window (`Form`), a start-at-login toggle backed by the
launchd agent, and a one-time onboarding sheet turns a script-installed tool
into an approachable Mac app (plan 000's bar #2).

## Current state

```swift
@main
struct DynamicIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        Settings { EmptyView() }   // <- replace this
    }
}
```
(`DynamicIslandApp.swift:5-13`)

`Setup` facts: launch agent label `com.bantay-tui.agent` installed by
`scripts/setup.sh` at `~/Library/LaunchAgents/com.bantay-tui.agent.plist`;
`KeepAlive`, `RunAtLoad`. The user already has a way in the shell; we want a
toggle.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Format lint | `swift format lint --recursive --strict Sources Tests` | exit 0 |
| Build | `swift build` | exit 0, zero warnings |
| Release | `swift build -c release` | exit 0 |

(`swift test` not runnable here; XCTest suite lives under
`Tests/BantayTUILogicTests` and runs in Xcode CI.)

## Scope

**In scope**:
- `Sources/BantayTUI/` new file `SettingsView.swift` (a SwiftUI `Form`).
- `Sources/BantayTUI/DynamicIslandApp.swift` — wire the Settings scene to the new view.
- `Sources/BantayTUI/NotchHUDConfig.swift` — add `launchAtLogin`, `hideAtStartup`, `notificationsEnabled` keys if not already present (reuse existing keys where possible).
- `Sources/BantayTUI/AppDelegate.swift`? — no; AppDelegate lives in `DynamicIslandApp.swift`; add a small `@objc func toggleLaunchAtLogin` helper there.
- A `LaunchAtLogin` helper (see M1) either as a tiny internal type or inlined — prefer inlined to avoid dependencies.

**Out of scope**:
- Per-source mute list UI (that is 005).
- Quiet-hours UI (005).
- Any menu-bar changes (001).
- Signing/notarization.

## Repo conventions

- SwiftUI views in `Sources/BantayTUI/` follow the existing style: `.accessory`, dark-friendly, mono `NSPanel`; the Settings window is a normal macOS Settings scene (light/dark), SwiftUI `Form` is fine.
- Config: `NotchHUDConfig` singleton, `didSet` persist to UserDefaults (`BantayTUI` domain).
- Avoid `#if DEBUG` test-alert shenanigans: the `testAlert` action (bug: it's DEBUG-only `publishForTesting`; DEV_PLAN Phase 3.1 calls to promote as "Send test notification"). Keep the menu `Test Alert` but ALSO expose a button in Settings calling the same sound; move `publishForTesting` out of `#if DEBUG` guarded app paths by giving it an `internal` visibility gate — be conservative: leave `#if DEBUG` as is and have the Settings button call `AgentEventManager.shared.publishForTesting()` only in DEBUG builds, presenting a "not available in release" tooltip otherwise. Document this choice in the saw.

## Steps

### Step 1: Launch-at-login helper (façade over launchctl)

Add in `DynamicIslandApp.swift` (or a new `LaunchAtLogin.swift` — decide when scaffolding) a small internal helper:

```swift
enum LaunchAgent {
    static let label = "com.bantay-tui.agent"
    static let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/com.bantay-tui.agent.plist"

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistPath) }
    static var isLoaded: Bool {
        // launchctl print gui/<uid>/com.bantay-tui.agent, exit 0 => loaded
        // (run via Process; see HerdrSocketAdapter for the run-CLI pattern)
        ...return exit status == 0
    }
    static func setLaunchAtLogin(_ on: Bool) {
        // on: run scripts/setup.sh if binary present (it copies + bootstraps)
        // off: launchctl bootout gui/<uid>/<label>; delete plist
        // Follow setup.sh's exact commands, wrapped in Process()
    }
}
```

Keep shell-out synchronous-but-fast; these are rare user actions. Use `Process` exactly like `HerdrSocketAdapter` does (there is an existing helper for running CLI commands with `waitUntilExit`; reuse it).

**Verify**: `swift build` → exit 0 (compile the new file). Manual: run the executable, open Settings, toggle; confirm `launchctl print gui/$(id -u)/com.bantay-tui.agent` returns the booted state you set.

### Step 2: Settings `Form` view

Create `SettingsView.swift`:

```swift
struct SettingsView: View {
    @State private var captureEnabled   = NotchHUDConfig.shared.captureEnabled
    @State private var captureInterval = NotchHUDConfig.shared.captureInterval
    @State private var enableAlerts    = NotchHUDConfig.shared.enableAgentAlerts
    @State private var soundVolume     = NotchHUDConfig.shared.soundVolume
    @State private var autoClearTTL    = NotchHUDConfig.shared.autoClearTTL
    @State private var stickyTTL       = NotchHUDConfig.shared.stickyApprovalTTL
    @State private var hideAtStartup   = NotchHUDConfig.shared.hideAtStartup
    @State private var launchAtLogin   = LaunchAgent.isLoaded
    @State private var quietHoursEnabled = NotchHUDConfig.shared.quietHoursEnabled // 005 will wire

    var body: some View {
        Form {
            Section("Capture") { Toggle/steppers for captureEnabled/captureInterval }
            Section("Alerts") { Toggle addAlerts + Slider volume; "Send test notification" button (DEBUG gate: `#if DEBUG Button(...) #endif`) }
            Section("Clear") { autoClearTTL, stickyTTL steppers }
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)   // calls LaunchAgent.install/uninstall in `onChange`
                Toggle("Hide island at startup", isOn: $hideAtStartup)
            }
            Section("Quiet hours") { // placeholder for 005; only ship the toggle+time pickers once 005 exists
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 520)
        .onAppear { /* refresh from config */ }
        .onDisappear { /* write all @State back to config */ }
    }
}
```

Apply convention: hot-apply instantly — write to `NotchHUDConfig.shared` in each `onChange`, not only on disappear (matches "settings changes hot-apply" requirement from DEVELOPMENT_PLAN Phase 3.3). Write-through on `.onChange(of:)` for each field; mirror with `config.didSet` side effects (ppoll interval, TTL re-read per tick already).

Avoid `Slider` knob-position-to-Float float rounding weirdness: use `Stepper(value:in:step:)` for volume/TTLs.

### Step 3: Wire the Settings scene

Replace `Settings { EmptyView() }` with:

```swift
Settings { SettingsView() }
```

This also makes Cmd+, do something real.

### Step 4: Onboarding sheet

Add to `DynamicIslandApp` (or `NotchStatusView.body`'s outer `onAppear`):

- `@AppStorage("hasSeenOnboarding") var hasSeenOnboarding = false`
- Present a one-time sheet on first launch ("Welcome"). Content: (1) what the pill is + a row-per-agent peek, (2) "herdr plugin link" tip, (3) toggles `hideAtStartup` and `launchAtLogin`, (4) Done. Re-openable from Settings ("Show Welcome…").

Keep it one screen, skippable, ~12 lines of SwiftUI.

### Step 5: Format + gates

**Verify**: `swift format lint --recursive --strict Sources Tests` → exit 0
**Verify**: `swift build` → exit 0, no warnings
**Verify**: `swift build -c release` → exit 0

## Test plan

- Unit-test `LaunchAgent.install(at:)`/`isInstalled`/`isLoaded` logic behind a
  thin protocol so CI can assert without shelling out (mock
  `launchctl print` output). Add to `Tests/BantayTUILogicTests`: a test that
  `LaunchAgent.isLoaded` parses the `launchctl print gui/.../<label>` exit
  correctly for the "not running" case and "running" case, via an injected
  `ProcessRunner`.
- Follow pattern: existing suite is pure-logic XCTest; add new case class
  `SettingsLogicTests`.
- Not runnable here (`swift test` needs Xcode) — CI Layer 3 will run them.

## Done criteria

- [ ] `swift build` zero warnings; `swift build -c release` zero warnings
- [ ] `swift format lint --strict` green
- [ ] Cmd+, opens a real grouped `Form` with at least: capture on/off,
      interval, alert sounds + volume, both TTLs, Launch at login,
      Hide at startup, test-notification (enabled state)
- [ ] Toggling "Launch at login" off runs `launchctl bootout gui/<uid>/com.bantay-tui.agent` and removes the plist; toggling back restores (verified on a real Mac with `launchctl print gui/<uid>/com.bantay-tui.agent`)
- [ ] Test notification visibly/alably plays a sound when alerts enabled
- [ ] Onboarding appears once, reappears from Settings
- [ ] No files outside Scope modified (`git status`)
- [ ] `plans/README.md` row updated

## STOP conditions

- The `Settings { … }` scene or `NotchHUDConfig` no longer match the excerpts
  (001 changed the file; re-base)
- `LaunchAtLogin` shelling out to `scripts/setup.sh` from within the app turns
  out to be impossible in app sandbox mode (we are not sandboxed) — proceed.
- A CI layer complains about `#if DEBUG`-only symbols leaking into release.
  In that case promote `publishForTesting` out of `#if DEBUG` into `internal`
  (that's what DEV_PLAN 3.1 intends), which is a 3-line change in
  `AgentEventManager.swift` — this promotion is part of the plan.

## Maintenance notes

- 005 quiet-hours UI slot here (`Section("Quiet")`) — reserve the key.
- The "Hide at startup" flag reads in `NotchStatusView.updateIslandVisibility`
  2020 (1) — update condition there to also check `!config.hideAtStartup` when
  the app is booting (before first event). Consider a `didLaunchOnce` flag that
  flips after `applicationDidFinishLaunching` so you don't permanently hide.
- Sparkle settings UI (003) nests into the same Form as an "Updates" section.