# Plan 001: Lifecycle controls in the menu bar (Hide / Snooze / Disable / Restart / Quit)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report  -  do not improvise. When done, update the status row for this plan
> in `plans/README.md` unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat b3a29ef..HEAD -- Sources/BantayTUI`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: direction
- **Planned at**: commit `b3a29ef`, 2026-08-02
- **Issue**: none

## Why this matters

Today the only user-initiated ways to stop the island are Quit (kills the
whole app, and the `KeepAlive` LaunchAgent restarts it any minute) or switching
off "Poll agents" (still shows events). There is no "hide for now", "snooze
for 10 minutes", no "disable until next launch", no restart of just the
pipeline. Per plan 000's baseline bar, being able to make the pill go away is
the #1 usability requirement of every notch competitor. This plan adds those
controls to the existing menu bar, with persisted state so the dismissed pill
stays dismissed until the user or the OS wakes it.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Format lint | `swift format lint --recursive --strict Sources Tests` | exit 0 |
| Build | `swift build` | exit 0, **no warnings** (CI Layer 2 warnings-as-failures) |
| Release build | `swift build -c release` | exit 0 (CI Layer 4) |

`swift test` (CI Layer 3) needs Xcode and is not runnable in the
CommandLineTools environment; the build gates above are the local check.

## Current state (excerpts to match against)

- Menu is rebuilt every open in `DynamicIslandApp.swift`:

```swift
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let titleItem = NSMenuItem(title: "Bantay-TUI", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(.separator())
        // ... agent list ...
        // "Poll agents" / "Alert sounds" toggles
        // DEBUG "Test Alert"
        let quitItem = NSMenuItem(title: "Quit Bantay-TUI", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
```

- Config lives in `NotchHUDConfig` (`Sources/BantayTUI/NotchHUDConfig.swift`),
  a `@MainActor` singleton over UserDefaults (`BantayTUI` domain) with
  `didSet { defaults.set(...) }` per property. Add new keys the same way —
   see "Repo conventions".

- Visibility is controlled by `NotchStatusView.updateIslandVisibility()`
  (currently shows when `currentEvent != nil || !agents.isEmpty`, else
  `AppDelegate.hide()`). Snooze/disable must join that gate.

## Scope

**In scope**:
- `Sources/BantayTUI/NotchHUDConfig.swift`  -  add 2 persisted keys.
- `Sources/BantayTUI/DynamicIslandApp.swift`  -  menu items + handlers.
- `Sources/BantayTUI/NotchStatusView.swift`  -  honor graceful state in the gate.
- `Tests/BantayTUILogicTests/*`  -  only if a pure-function seam is added (prefer
  adding the new-key read/write tests against `NotchHUDConfig` if the harness
  supports it; see Test plan).
- `plans/README.md`  -  status row.

**Out of scope** (do NOT touch):
- Settings window (plan 002), update engine (003), uninstall (004), quiet
  hours/mute (005).
- The `.accessory` activation policy, the LaunchAgent install (that is the
  004 plan's business).

## Repo conventions you must match

- 2-space indentation, `swift-format` style (`.swift-format` pins rules;
  run `swift format format --in-place` before committing and `lint --strict`
  in the gate).
- `@MainActor` on all UI code; `NotchHUDConfig.shared` is the config singleton.
- Menu items are built inline in `menuNeedsUpdate(_:)`, state toggles use
  `item.state = .on`, actions are `@MainActor @objc private func ...`.
- Persistence pattern to copy:
  `var captureEnabled = true { didSet { defaults.set(captureEnabled, forKey: "captureEnabled") } }`
  plus load in `init()`.
- All UI strings short title-case, matching "Poll agents".

## Steps

### Step 1: Add persisted control state to `NotchHUDConfig`

Add to `NotchHUDConfig`:

```swift
var islandEnabled = true {        // master "don't show anything today" switch
    didSet { defaults.set(islandEnabled, forKey: "islandEnabled") }
}
var snoozedUntil: Date? { ... } // persisted via defaults  -  follow the existing pattern; store as TimeInterval since reference date or ISO8601 string
```

- Skip: NOT persisted per event on every set — read the same method as the
  `init()` loads keys. `snoozedUntil` should default to nil.
- Helper: `var isSnoozed: Bool { snoozedUntil?.timeIntervalSinceNow ?? 0 }) > 0`. (put.)

**Verify**:
`swift build` → exit 0
`grep -n "snoozedUntil\|islandEnabled" Sources/BantayTUI/NotchHUDConfig\.swift` → matches present.

### Step 2: Gate `NotchStatusView.updateIslandVisibility()` on the user's intent

In `NotchStatusView.swift` find:

```swift
private func updateIslandVisibility() {
    if eventManager.currentEvent != nil || !eventManager.agents.isEmpty {
        AppDelegate.showAtNotch()
    } else {
        AppDelegate.hide()
    }
}
```

Replace with:

```swift
private func updateIslandVisibility() {
    let config = NotchHUDConfig.shared
    if config.islandEnabled && !config.isSnoozed,
       eventManager.currentEvent != nil || !eventManager.agents.isEmpty {
        AppDelegate.showAtNotch()
    } else {
        AppDelegate.hide()
    }
}
```

The gating is read on every event/agents change, so a snooze or disable takes
effect immediately (island hides) and re-enabling shows it again naturally.

**; Verify**: `swift build` → exit 0
**; Verify**: `grep -n "islandEnabled && !config.isSnoozed" Sources/BantTayTUI/NotchStatusView\.swift` → match present.

### Step 3: Add the control group to the menu (Menu bar rebuild)

In `menuNeedsUpdate(_:)` in `DynamicIslandApp.swift`, just before the
`separator()` that precedes the `#if DEBUG` block (i.e., between the existing
"Alert sounds" item and the separator at line ~179), insert a new section:

```swift
menu.addItem(.separator())

let disableItem = NSMenuItem(
    title: config.islandEnabled ? "Disable Island" : "Enable Island",
    action: #selector(toggleIslandEnabled),
    keyEquivalent: "")
disableItem.target = self
menu.addItem(disableItem)

let snoozeItem = NSMenuItem(
    title: config.isSnoozed ? "Snooze 10 minutes… (active)" : "Snooze 10 minutes",
    target-set)
snoozeItem.action = #selector(snoozeTen)
snoozeItem.target = self
// state .on when isSnoozedelse .off
menu.addItem(snoozeItem)

menu.addItem(.separator())
```

(Submenu-with-icon style: match how `Poll agents` is a state item; put these
two plus `Restart pipeline` and keep Quit at the bottom.)

Handlers (in the AppDelegate, alongside `togglePolling`):

```swift
@MainActor
@objc private func toggleIslandEnabled() {
    let config = NotchHUDConfig.shared
    config.islandEnabled.toggle()
    // island state observed via agent events polling; poke the view once:
    NotificationCenter.default.post(name: .notchVisibilityChanged, object: nil)
}

@MainActor
@objc private func snoozeIsland() {
    let config = NotchHUDConfig.shared
    if config.isSnoozed {
        config.snoozedUntil = nil
    } else {
        config.snoozedUntil = Date().addingTimeInterval(600)
    }
    NotificationCenter.default.post(name: .notchVisibilityChanged, object: nil)
}
```

Add a `private extension Notification.Name { static let notchVisibilityChanged = Notification.Name("notchVisibilityChanged") }` (top-level in a file already imported) and in `NotchStatusView` `.onReceive(NotificationCenter.default.publisher(for: .notchVisibilityChanged)) { _ in self.updateIslandVisibility() }` (attach to the existing `body`'s stack, alongside the existing `onAppear`/`onChange`).

**; Verify**: `swift build` → exit 0 & no warnings; menu, when open, has the new group and state toggles.

### Step 4: Also give the row of `Focus` a per-pane "mute source" lever

Optional, in `menuNeedsUpdate` after each agent row: select the still-agent row and look up the source; do *not* implement per-source mute now (that is plan 005). Only note in a comment that per-source mute is planned, so the executor does not expand scope.

### Step 5: verify tests + format

**; RUN**: `swift format lint --recursive --strict Sources Tests` → exit 0
**; RUN**: `swift build -c release` → exit 0

## Test plan

- Follow pattern: `Tests/BantayiTUILogicTests/` apex: the suite is XCTest, runs
  only under Xcode. Add at least:
  - `NotchHUDConfig`: load saves/restores `islandEnabled` and `snoozedUntil`
    (reset the defaults in `setUp` with `UserDefaults.standard.removePersistentDomain(forName: "BantayTUI")`).
  - `isSnoozed` true when `snoozedUntil` in the past, false otherwise.
- These tests don't run in this environment; create the file but only gate on
  the compile + `swift build` in CI at Layer 2/3 (the PR runs `swift test`).

## Done criteria

All must hold:
- [ ] `swift format lint --recursive --strict Sources Tests` exit 0
- [ ] `swift build` exit 0 **with zero warnings**
- [ ] `swift build -c release` exit 0
- [ ] Menu shows "Disable Island"/"Enable Island" toggling correctly; snooze
      item flips state; Quit still last
- [ ] `NotchHUDConfig` persists `islandEnabled`/`snoozedUntil` (drive with a
      `defaults` read in a REPL or `launchctl print`… simplest is relighting
      the listener: user toggles, relaunches, state retained)
- [ ] No files outside the in-scope list modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:
- The `updateIslandVisibility` or `menuNeedsUpdate` code no longer matches the
  excerpts above (repo drifted since b3a29e6; bring the plan's bits forward or
  ask for a re-plan).
- A step's verification fails twice after a reasonable fix attempt.
- `swift build` starts warning about the `Notification.Name` extension colliding
  with an existing name (there is none at b3a29ef; if there is, rename to
  `bant ay-ux.visibilityChanged`).
- You realize the plan would need to modify `scripts/setup.sh` (it doesn't; that is 004).

## Maintenance notes

When plan 005 lands, this island's "snooze" and "disable" states compose with
quiet-hours (grand: island hidden during quiet hours as well). The
`notchVisibilityChanged` notification becomes the central "visibility
conditions changed" signal that 002's Settings controls will also broadcast,
so keep its name and behavior stable.