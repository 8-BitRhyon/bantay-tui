# Plan 005: Quiet hours, per-source mute, and snooze persistence

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm its expected result before moving on. If a
> STOP condition appears, stop and report — do not improvise. Update your row
> in `plans/README.md` when done unless a reviewer said they are handling the
> index.
>
> **Drift check (run first)**: `git diff --stat b3a29ef..HEAD -- Sources/BantayTUI`
> In-scope files: `NotchHUDConfig.swift`, `NotchStatusView.swift`,
> `AgentEventManager.swift`, `DynamicIslandApp.swift`. If any differ materially
> from the excerpts, reconcile; on mismatch treat as STOP.

## Status

- **Priority**: P2
- **Effort**: S (M if you land the Settings UI too)
- **Risk**: LOW
- **Depends on**: 002 (Settings UI home for the quiet-hours toggles) and
  001 (`snooze` state exists; this adds the schedule + mute sets on top).
- **Category**: direction
- **Planned at**: commit `b3a29ef`, 2026-08-02
- **Issue**: none

## Why This Is

The user's concrete complaint is "sometimes it can be quite annoying." That's
two separate annoyances: (1) sounds/per-event pops at 2am and (2) a chatty
source (e.g. `freebuff` or `command-demo`) flooding the identical label.
Competition: MediaMate (quiet hours), BoringNotch (mute whole alerts + sound
toggle), and NotchDrop's subset — plus the `snooze`/`islandEnabled` we already
get. Here it will:

- add a "Do Not Disturb" quiet-hours window (visual-only; no sounds, silent
  pill ideally):
- add per-source mute (once muted, the source never produces a sound or
  event??—config: events still show but muted pills are dimmed and no sound; or
  fully suppressed for the [default: no sounds, still visually shows]. pick
  "silent events").
- make snoozing compose: `snoozedUntil` + quiet hours + source-muted all
  reduce shows/sound but never permanently lose a `blocked` approval that
  must still be answerable.

This delivers 000's "make it stop" without any data loss (approvals still
surface).

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Format lint | `swift format lint --recursive --strict Sources Tests` | exit 0 |
| Build | `swift build` | exit 0, no warnings |
| Release | `swift build -c release` | exit 0 |

## Current state

- `NotchHUDConfig`: has global `enableAgentAlerts` + `volume`; no quiet/,, per-source,
- `updateIslandVisibility()` (NotchStatusView) — control center.
- `AgentEventManager` maintains `agents` (roster) and muted-notification coding absent.
- `handleEventChange` plays sounds (via `playSound` — a `#if DEBUG` promotion
  aside is planned in 002).

## Scope

**In scope**:
- `NotchHUDConfig.swift` — new keys:
  - `quietHoursEnabled` (Bool, default false)
  - `quietHoursStart` (Int hour 0–23, default 22)
  - `quietHoursEnd` (Int hour 0–23, default 8)
  - `mutedSources: [String]` (persisted as `[String]`; e.g. `UserDefaults
    .set(mutedSources, forKey: "mutedSources")`)
- `AgentEventManager.swift` — a pure `shouldPlaySound(for source:kind:)` and an
  `isMuted(source:)` using `NotchHUDConfig.shared.mutedSources`; gate sound
  and duplicates accordingly.
- `NotchStatusView.swift` — in the visibility gate and in `handleEventChange`,
  honor quiet-hours (visual only, no ding) and mute (suppress ding, still
  light the pill so nothing is missed).
- `DynamicIslandApp.swift` — menu: "Mute this source" on each agent row;
  a "Quiet hours…" submenu toggling UI (simple `menuItem.state`).
- `SettingsView.swift` (from 002) — Section("Quiet hours") with the two
  steppers + enabled toggle; Section("Muted sources") list with removal chevron.

**Out of scope**:
- Renaming `enableAgentAlerts` or `soundVolume` (existing config names).
- Row-level swipe gestures in the island UI (a future Phase-2 feature; now
  only menu-level).

## 4. Conventions

- All new config keys in `NotchHUDConfig` follow the existing `var x = def { didSet { defaults.set(x, forKey: "x") }}` + `init()` read pattern.
- Menu items: `menuNeedsUpdate` style; use `state = .on`/`.off`.
- Pure logic additions to `AgentEventManager` should be testable without UI.

## 5. Steps

### 1. Config keys (NotchHUDConfig)

```swift
var quietHoursEnabled = false { didSet { defaults.set(quietHoursEnabled, forKey: "quietHoursEnabled") } }
var quietHoursStart = 22   { didSet { defaults.set(quietHoursStart, forKey: "quietHoursStart") } }
var quietHoursEnd = 8      { didSet { defaults.set(quietHoursEnd, forKey: "quietHoursEnd") } }
@Published? not used; mutedSources: [String] = [] { didSet { defaults.set(mutedSources, forKey: "mutedSources") } }
```

Load in `init()` mirroring existing style.

`var isWithinQuietHours: Bool` computed:

```swift
var isWithinQuietHours: Bool {
    guard quietHoursEnabled else { return false }
    let h = Calendar.current.component(.hour, from: Date())
    if quietHoursStart == quietHoursEnd { return false } // 24h off
    if quietHoursStart < quietHoursEnd { return h >= quietHoursStart && h < quietHoursEnd }
    return h >= quietHoursStart || h < quietHoursEnd          // e.g. 22:00–08:00
}
```

Add `func isMuted(_ source: String) -> Bool { mutedSources.contains(source) }`.

### 2. Sound+pill suppression in `AgentEventManager` / `NotchStatusView`

Add to `AgentEventManager`:

```swift
func shouldPlaySound(for event: AgentEvent) -> Bool {
    guard NotchHUDConfig.shared.enableAgentAlerts else { return false }
    if NotchHUDConfig.shared.isMuted(event.source) { return false }
    return true // per-event storms handled elsewhere; plan only adds mute+quiet
}

var priority: `.blocked` > `.done` > `.working` unchanged
```

In `NotchStatusView.updateIslandVisibility()` keep showing (quiet hours hide
nothing; they silence) — but add a companion:

```swift
private func quietMode() -> Bool { NotchHUDConfig.shared.isWithinQuietHours }
```

and gate *sounds* there, not visibility (an approval must still be visible;
quiet hours are about audio). In `handleEventChange` where a sound plays,
wrap with `if !NotchHUDConfig.shared.isWithinQuietHours && !NotchHUDConfig.shared.isMuted(event.source) { play() }` (find the exact sound-call site in `handleEventChange` to modify — 2 places incl. possibly `AgentEventManager` if it emits sound there).

### 3. Menu actions

Add to `menuNeedsUpdate` per agent row: a submenu (arrow-in) on each row
"…Mute «source»" (state on if muted) → `#selector(toggleMute(_:))` with
`representedObject = source`.

Add two rows:

```swift
// for each muted source: "Unmute <source>"
let quietItem = NSMenuItem(title: config.isWithinQuietHours ? "Quiet Hours: On" : "Quiet Hours: Off",
                           action: #selector(toggleQuietHours))
```

Handlers:

```swift
@objc private func toggleMute(_ item: NSMenuItem) {
    guard let source = item.representedObject as? String else { return }
    var muted = NotchHUDConfig.shared.mutedSources
    if muted.contains(source) { muted.removeAll { $0 == source } } else { muted.append(source) }
    NotchHUDConfig.shared.mutedSources = muted
}
@objc private func toggleQuietHours() { NotchHUDConfig.shared.quietHoursEnabled.toggle() }
```

### 4. Settings section (only if 002 landed)

In the `Form`:

```swift
Section("Quiet hours") {
    Toggle("Quiet hours", isOn: $quietHoursEnabled)
    Stepper("Start \(quietHoursStart):00", value: $quietHoursStart, in: 0...23)
    Stepper("End \(quietHoursEnd):00",   value: $quietHoursEnd, in: 0...23)
}
Section("Muted sources") {
    ForEach(mutedSources, id: \.self) { Button($0) { unmute($0) } }
    if mutedSources.isEmpty { Text("None") }
}
```

### 6. Verify

- `swift format lint --recursive --strict Sources Tests` exit 0
- `swift build` exit 0 warnings 0; `swift build -c release` exit 0
- Manual: set quiet hours to now, "Alert sounds" on, trigger a test event → NO
  sound, pill still shows. Mute one source, fire it → sees event, silent.

## 6. Test plan

Add to `Tests/BantayTUILogicTests` (Xcode-only but write anyway):
- `NotchHUDConfigTests.quietHours` — boundary midnight (23:00–07:00),
  equal-start case, toggle-off.
- `isMuted` true/false; empty list default.
- `enforce: mutate config through main actor defaults; resetter reset each test
  from `MuteDefaults`.

## 7. Done criteria

- [ ] quiet-hours configured in Settings + menu status shows On/Off
- [ ] During quiet hours: no sound on events, pill still visible
- [ ] Muted source: events visible, silent; unmute restores sound
- [ ] Snooze (001) composes: `snoozedUntil` hides; quiet hides sound only
- [ ] `swift -format` lint + build + release green, zero warnings
- [ ] tests written for quiet/`isMuted`
- [ ] `plans/README.md` row updated

## STOP conditions

- If silent events would hide an *approval* prompt (blocked), that's a product
  blocker; quiet hours must never suppress `blocked`/approval visibility.
  Revisit and STOP if you find a path where quiet hours or mute hides a
  `blocked` pill (they must remain visible; only audible behavior changes).
- `mutedSources` persistence via `UserDefaults` for `[String]` uses
  `set(_:forKey:)`; on read use `array(forKey:) as? [String]` — don't force.

## 8. Maintenance notes

- This will be a DMG after signing; untouched.
- When 003's Sparkle ships, quiet-hours and update checks interplay:
  Sparkle checks happen regardless of quiet hours (fine).
- Later, row-level mute† on the roster (right-click) is the natural reentrance;
  the menu is a shortcut.