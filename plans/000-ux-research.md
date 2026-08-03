# Plan 000: UX research & usability baseline (the study)

> **Executor instructions**: This file is the *why* for plans 001–005. It is a
> read-only reference document  -  there is nothing to implement here. Executors
> and reviewers should read it before starting any other plan, and plans may
> cite its "Baseline bar" section as their acceptance standard.
>
> **Drift check (run first)**: `git diff --stat b3a29ef..HEAD` reveals nothing
> for this doc (docs are not drifted by source changes; treat edits to
> `plans/000-ux-research.md` as out of scope).

## Status

- **Priority**: P1 (guides the whole program)
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: direction
- **Planned at**: commit `b3a29ef`, 2026-08-02
- **Issue**: none

## Why this matters

The current build is functional but not yet a *selling point*: there is no way
to update it, no way to cleanly uninstall or remove its launch agent, no way
to disable or snooze the island, no Settings window (the app literally opens an
empty window for Cmd+,), no quiet hours, and no onboarding. Every other macOS
notch app that survives long-term solves these lifecycle problems, because a
pill that can't be turned off or updated becomes an annoyance, not a feature.
This plan captures what the competition actually does, distills an explicit
"base usability bar", and maps the gaps to executable plans 001–005.

## Current state (what Bantay-TUI looks like today)

Ground truth, verified against commit `b3a29ef`:

- Manifest `DynamicIslandApp.swift:8-12`: `Settings { EmptyView() }` —
  the preferences scene is a placeholder; Cmd+, opens a blank window.
- Menu bar (`DynamicIslandApp.swift:122-197`) is rebuilt per `menuNeedsUpdate`:
  agent rows → "Poll agents" / "Alert sounds" state toggles → (DEBUG) Test
  Alert → "Quit Bantay-TUI" (Cmd+Q). No Settings, no Disable, no Snooze,
  no Restart.
- Config (`NotchHUDConfig.shared`, UserDefaults domain `BantayTUI`):
  `enableAgentAlerts`, `soundVolume`, `autoClearTTL`, `stickyApprovalTTL`,
  `captureEnabled`, `captureInterval`, `muteInTerminal`. No `snoozedUntil`,
  no `islandEnabled`, no per-source mutes, no quiet-hours window.
- Launch agent: `scripts/setup.sh` installs `~/Library/LaunchAgents/
  com.bantay-tui.agent.plist` with `RunAtLoad` + `KeepAlive` and copies the
  binary to `~/Library/Application Support/Bantay-TUI/bantay`. There is NO
  `--uninstall` flag; removing the app requires manual
  `launchctl bootout` + plist/data cleanup the README does not document.
- Updates: none. `Package.swift` (see read below) has no update dependency;
  no `Sparkle`, no `SoftwareUpdater`, no "Check for Updates".
- UI state: the island is a SwiftUI `NSPanel` (hidden at login since commit
  `8ccd9e1` work in `NotchStatusView.updateIslandVisibility()` + the removal of
  `orderFrontRegardless()` in `makeIslandWindow()`); it self-hides when idle.
  The user's pain ("sometimes it can be quite annoying") is not that the
  island shows, it's that there is no *user-initiated* way to make it go away
  (or stay away) short of quitting the app.

## The study sources

Read for this plan (paths point at the pinned repos/files used):

| App | Status | What we read |
|---|---|---|
| BoringNotch (`TheBoredTeam/boring.notch`) | OSS (MIT) | `boringNotchApp.swift`, `models/BoringViewModel.swift`, `boringNotchApp.swift`, `Constants.swift`, `menu/StatusBarMenu.swift`, `components/Settings/{SettingsView,SettingsWindowController,SoftwareUpdater}.swift`, `components/Onboarding/*`, README |
| NotchDrop (`Lakr233/NotchDrop`) | OSS | `App.swift`, `NotchWindow/NotchWindow.swift`, `NotchView.swift`, `NotchDropApp.swift`, `NotchMenuView.swift`, `NotchSettingsView.swift`, `NotchViewModel+Events.swift`, `EventMonitors.swift` |
| NotchNook (lo.cafe) | Closed | marketing/FAQ pages, screenshots, "Shelf" product inverts |
| MediaMate (mediamate.app) | Closed | product page (site was down during part of the study — flagged, low-confidence), public knowledge of its HUD behavior |
| Notchly (notchly.cc) | Closed | product docs/screenshots |

## What the competition does (dimension by dimension)

### 1. First run / onboarding
- **BoringNotch**: a real onboarding flow (`OnboardingView` → `WelcomeView` →
  `PermissionsRequestView` → `MusicSlotConfigurationView` → `OnboardingFinishView`)
  that sets up music/queue/permissions and ends with a "done" screen. It is
  skippable and never repeats what you've already configured.
- **NotchDrop**: no formal onboarding; the drop-on-notch behavior is the
  tutorial. First manual launch plays a deliberate `.boot` open animation.
- **Bantay today**: no onboarding; the user discovers features by trial.
- **Bar**: show a one-time intro on first launch that (a) shows what the pill
  is, (b) tells the user how to install the herdr plugin hook
  (`herdr plugin link`), (c) gives a "Hide pill at startup" toggle, (d) is
  re-showable from Settings. One window, no permissions to chase.

### 2. Idle appearance & "the pill is in my face"
- **BoringNotch**: `hideOnClosed` collapses the closed notch to a near-zero
  height / or a tiny notch-sized rectangle on notch-has displays; on notchless
  screens it hides entirely until hovered. `extendHoverArea` defaults to false.
- **NotchDrop**: closed shows a faint 30% ghost that fades in 0.5 s; *nothing*
  at login-launch (`isLaunchedAtLogin` stays invisible). Pops only when the
  cursor enters the notch rect (global `EventMonitors`).
- **NotchNook / MediaMate**: at rest invisible; event-driven only.
- **Bantay today**: hidden at login already (see Current state), shows when a
  herd event fires or agents are live. Good default. **Missing**: the user's
  "make it go away" lever.

### 3. Control: disable / snooze / hide / quit / restart
- **BoringNotch**: menu bar item ("music.note") with Quit; Settings has a
  "Hide . You can also hide the closure notch" style toggles; the notch itself
  supports keyboard shortcut to hide.
- **NotchDrop**: the notch itself opens a **menu layer** (`NotchMenuView`) with
  ↑ Exit (stop app), ⚙ Settings, 🗑 Clear. Quit is an explicit first-class
  action, red, in the biggest surface.
- **Bantay consumes**: there is currently no "Hide for now", no snooze, no
  way to stop the pill except Quit.
- **Bar**: a menu-bar control group that lets the user (1) Hide the island now
  (valid until the next explicit event / roster change, with a "Unhide" and
  "Snooze 10 min" sub-options), (2) Disable the island entirely until next
  launch, (3) Restart the core (poll+adapter) without Quit, (4) Quit. Persist
  the "disabled until next launch" so the pill you dismissed does not come back
  while the user is trying to work. See plan 001.

### 4. Settings surface
- **BoringNotch**: full `SettingsWindowController` + `SettingsView` Form that
  hot-applies (poll, sound, appearance, update prefs, hiding).
- NotchDrop: notch-internal Settings popover (LaunchAtLogin via `LaunchAtLogin`
  package, file storage time, haptics toggle).
- **Bantai**: `Settings { EmptyView() }` — blank preferences window.
- **Bar**: real Settings Form (capture on/off + interval, alert sounds + volume,
  TTLs, "Start at login" toggle, quiet hours, per-agent mute, "Hide at
  startup", update prefs, "Send test notification"). Changes hot-apply.
  See plan 002.

### 5. Updating
- **BoringNotch**: Sparkle. `SoftwareUpdater.swift` exposes
  "Check for Updates…" (in Settings) and `UpdaterSettingsView` toggles for
  "Automatically check / Automatically download". Their Sparkle
  `CheckForUpdatesViewModel` drives a button state.
- **NotchContent**: `sparkle`? no — non-app uses `Sparkle` too (matrix: uses
  upchecker.package). Closed apps update via the Mac App Store or their own
  updater/Script.
- **Bantay**: none. `Package.swift` has zero dependencies; no way to know a new
  version exists.
- **Bar**: Sparkle (or a `gh releases` fallback), with auto-check on,
  auto-download opt-in, and a "Check for Updates…" entry in Settings AND the
  menu. Signing/notarization is a prerequisite (see 003).

### 6. Removing / uninstalling
- **BoringNotch**: not installer-annointed; removal = quit + trash + remove
  launch-at-login. (Most notch apps are App-Store or Finder-apps; no system
  hooks.)
- Not a concern: the agent stays; NotchDrop ships `.pkg`-less, uninstall = quit.
- **Bantay**: this is the *hardest* story — `setup.sh` installs a
  `RunAtLoad + KeepAlive` LaunchAgent that relaunches the app on any quit/air.
  A user that drags the app to Trash still gets killed by the agent. There is
  no `--uninstall` and the README tells them how to get the agent back only.
- **Bar**: `scripts/setup.sh --uninstall` that (boots out the agent, deletes
  the plist + data dir including `agent-events.jsonl`, leaves nothing behind),
  plus an in-app menu path and a documented "How to completely remove" with
  symptoms. See plan 004.

### 7. Annoyance: quiet hours, per-source mute, event storm damping
- **MediaMate**: silent-hours / Do Not Disturb awareness; auto-collapse by
  music app; individualized toggles.
- **BoringNotch**: no worry — notifications prefer settings, sounds per event,
  repeats suppressed.
- **NotchNook**: extensive (per-source), disable-animation, fade-only.
- **Bantay**: has global `enableAgentAlerts` + `soundVolume`, and
  `stickyApprovalTTL`, but no per-source mute and no time window.
- **Bar**: per-source mute (menu + row action), and "Quiet hours" window
  (default 22:00-08:00 → visual-only, no sounds), event-storm guard (already
  planned in DEVELOPMENT_PLAN Phase 1.4). See 005.

### 8. Data & lifecycle hygiene
- **Bantay writes `agent-events.jsonl` unbounded; delete process is not
  automated.** Competitors (NotchDrop) auto-rotate shelf/queue files, delete
  old items.
- **Bar**: cap the events file (size-rotate in the app or adapter) and expose
  "Clear history now" in Settings; document where data lives. Folded into
  004 (cleanup) and 002 (a "Data" row).

### 9. Launch-at-login
- All notable competitors use a first-class "Open at login" toggle in the UI
  (NotchDrop's `LaunchAtLogin.Toggle`, BoringNotch/others), not only a script.
- Bantay currently only via `setup.sh` (a script), no in-app toggle.
- **Bar**: "Launch at login" toggle in Settings (and available in onboarding),
  using the launchd plist, exposing whether the agent is installed.
  Folded into plan 002.

## The "base usability bar" (this is the selling point bar)

A notch app is usable when the user can answer these five questions about it
without touching a terminal:

1. **"What is that pill and how do I make it stop?"** → Show answers in
   onboarding + always-reachable menu ≥ Hide / Snooze / Disable / Quit.
2. **"How do I change how it behaves?"** → Settings window with everything the
   config supports (plan 002).
3. **"How do I get the newer versions?"** → "Check for Updates…" + auto-check in
   Settings and a menu item (plan 003).
4. **"How do I remove it completely?"** → `setup.sh --uninstall` + in-app
   action + README section (plan 004).
5. **"Can it stop nagging me on nights/lunch?"** → Quiet hours + per-source
   mute + snooze (plan 005).

Nothing in the bar is a "nice idea"; each item is the minimum that converts a
curiosity into a daily driver, and each is directly called out by the
competion above.

## Plan mapping

| Plan | Delivers |
|---|---|
| 001 | Recommend animate/disable/snooze/quit/restart controls in Menu bar (answers "how do I disable/remove this thing") |
| 002 | Settings window (real `Form`, replaces `EmptyView`), onboarding sheet, Launch-at-login toggle |
| 003 | Sparkle auto-update + "Check for Updates…" |
| 004 | `setup.sh --uninstall` + in-app cleanup + README removal guide |
| 005 | Quiet hours + per-source mute + snooze persistence (answers "sometimes it can be quite annoying") |

## Considered and rejected

- **Full-notch compositing** (draw a fake notch over the menu bar, BoringNotch-style):
  invasive, conflicts with transparency-through design and menubar
  managers. Rejected.
- **Global mouse tracking**: re-introduces the "expands far from the notch" bug.
  Rejected; island-scoped hover stays.
- **Shelf / widget ecosystem** (NotchNook shelf, info widgets): out of focus for a
  first baseline; the stock stays an agent-status surface.
- **Homebrew cask in this round**: master (referenced for 003) — not planned; it
  is already noted as a DEV_PLAN Phase 5.4 future.