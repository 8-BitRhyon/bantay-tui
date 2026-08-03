# Plan 010 — Speed & peripheral-vision snacks

Status: done (commit `f3c2fe0`, signed `security-signing@monozen.local`).

## Goal
Ship the 8 bite-sized UX snacks proposed by review: keyboard speed,
peripheral-vision cues, and workflow controls — with the right default
(enabled-at-start vs settings) for each.

## Triage (impact → default)
| Snack | Default | Why |
|---|---|---|
| Global ⌥Space toggle | ON | Core "execute anywhere" pitch; zero friction |
| Keyboard shortcuts Y/N/1-9 | ON | Speed, keyboard-first |
| Edge glow on blocked | ON | Peripheral vision during meetings |
| Menu-bar badge | ON | Always-visible status |
| Copy prompt/message | ON | Utility, no noise |
| Snooze presets | ON (menu) | Menu-based, no settings needed |
| Elapsed timer | ON (toggle in Settings) | Visual noise for some |
| Sound preview | Settings-only | Test/calibrate volumes |

## What changed
- `IslandMetrics`: `elapsedLabel`, `shortcutKey` + `ApprovalShortcut`,
  glow colors.
- `AgentEventManager`: `startedAtByPane` burst tracking in `showEvent`,
  merged into roster snapshots via `mergeApprovals`; test seams
  `recordStartForTesting`/`clearStartForTesting`.
- `NotchStatusView`: edge-glow overlay (repeatForever, reduced-motion
  steady), 1s ticker for elapsed labels, `.focusable()` +
  `.onKeyPress` shortcuts, `notchHotkeyPressed` expand handler, copy
  context menu on queue cards.
- `DynamicIslandApp`: global ⌥Space key-down monitor (Sendable-safe,
  `AppDelegate.handleHotkeyToggle` static), menu-bar badge timer (3s),
  snooze presets submenu (15m/1h/4h/until-restart/cancel).
- `NotchHUDConfig`: `globalHotkeyEnabled`, `keyboardShortcuts`,
  `edgeGlowEnabled`, `showElapsedTime`, `menuBarBadge`,
  `snoozeUntilRestart` (isSnoozed honors it).
- `SettingsView`: "Quick actions" section + sound preview button.

## Gates
- `swift format lint --recursive --strict Sources Tests` — clean.
- `swift build` + `swift build -c release` — 0 warnings.
- Harness — RED-first L8 (elapsed labels, shortcut mapping, startedAt
  lifecycle, facet defaults/persistence, snooze-until-restart), `ALL PASS`.
- Installed + `launchctl kickstart -k` — island visible, no crash.

## Next
- Peek (captureTail) panel per queue card.
- tmux/zellij adapters behind `PlexerAdapter`.