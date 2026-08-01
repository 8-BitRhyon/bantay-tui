# Bantay-TUI Development Plan

Comprehensive roadmap for taking the notch HUD from working prototype to a polished, reliable, distributable macOS app. Everything is grounded in the current architecture (`ARCHITECTURE.md`) and the issues found during the island rebuild (PR #3).

## Current State

| Area | Status |
|---|---|
| Island | Notchly-style black island, fixed 456×240 `NSPanel`, centered, top-pinned under the notch; closed pill 160×36 below a 38pt safe-area strip; hover expands to a 320-wide roster |
| Visibility | Always-visible: event pill → "Agents · N" idle pill → empty bar; launchd agent restarts it |
| Pipeline | Polls `herdr agent list` every 2s (default) + optional JSONL event-file tail via the herdr plugin adapter |
| Logic core | Pure `update()`: roster severity ordering, persistent working/blocked/started events, clear-on-vanish, silent re-show, TTL auto-clear; 24 local checks (`swiftc` harness) + CI XCTest suite |
| CI | 6-layer pipeline (format → build → test → release + secrets + pins), all green; Kilo Code Review required |
| Distribution | Manual: `swift build` + `scripts/setup.sh` (copies binary to `~/Library/Application Support/Bantay-TUI/`); ad-hoc signed only |

## Vision

The notch becomes the primary, glanceable surface for herdr agent activity: one hover shows every agent, its state, and what it's doing; one click focuses the pane; approvals, completions, and blocks are never missed even when the terminal is off-screen.

## Phase 1 — Hardening (next, highest value)

Tighten the edges exposed by the rebuild before adding features.

1. **Roster overflow** — expanded height is capped at the 240pt window (`min(topInset + content, 240)`); with 6+ agents rows clip. Approach: grow the window height with roster size (window can resize freely; the resize-snap observer already keeps it centered/top-pinned) or cap visible rows with a "N more" row. Acceptance: 10 agents render without clipping, hover still smooth.
2. **Multi-screen behavior** — currently `NSScreen.main` only. Approach: island follows the screen containing the hovered pointer or the herdr window; per-screen `topInset`; window server screen-change observer already exists. Acceptance: island appears on the screen where the user is looking, centered, on both notched and non-notched displays.
3. **Non-notched displays** — `topInset` falls back to menu-bar height; the "cutout" corners then sit over the menu bar. Approach: on non-notched screens keep the pill below the menu bar (Notchly's `usesIdleNotchSize` path) and reduce corner cutouts to a simple rounded bar. Acceptance: correct look on an external monitor.
4. **Event storms** — herdr can flip state rapidly (working → blocked → working); the 2s poll aggregates transitions but a flood of JSONL events can spam sounds. Approach: per-source-kind cooldown (e.g., ≥5s between sounds), dedupe consecutive identical titles, cap pending events. Acceptance: a blocked agent toggling repeatedly yields ≤1 sound per 5s.
5. **Poll cost** — a `herdr agent list` subprocess every 2s is wasteful. Approach (short-term): keep 2s but skip the poll when the app is frontmost-hosted to a screen that's asleep; revisit with Phase 4 socket adapter.
6. **Crash/launch resilience** — the launchd dyld hang under `~/Downloads` is fixed via the install location; add a startup guard: if the window cannot be created, log to `bantay.err` and exit cleanly (no silent half-launched process). Acceptance: corrupted state never leaves an invisible zombie agent.

## Phase 2 — Interactions & UX

Notchly-parity interactivity plus the herdr-specific ideas.

1. **Expanded states** — Notchly morphs through `agentCollapse` → `agentPreview` → `agentOpen` with idle-time collapse and hover-out expand. Add: expanded roster shows a "current event" header line (already present) and, on click of a row, an agent detail pane (title, cwd, workspace, revision) with actions.
2. **Row actions** — right-click a row: Focus pane, Copy title/cwd, Open workspace in Finder/terminal, Mute this source. Keyboard: Cmd+1..9 focuses the Nth agent (menu-bar roster already does this via click).
3. **Empty-bar hover** — the empty bar currently only expands the chrome; make it show a hint ("no active agents") or a compact herdr status (e.g., "2 terminals idle").
4. **Sound design** — per-kind sounds already exist; add per-source mute and a "quiet hours" window (e.g., 22:00–08:00 → visual only). Use the existing `enableAgentAlerts`/`soundVolume` config.
5. **Accessibility** — VoiceOver labels for rows, `accessibilityAction` on rows, reduced-motion: replace `.smooth` morphs with opacity fades when `reduceMotion` is on.
6. **Persistence of dismissal** — a "snooze this agent for 10 min" action (menu + row action) so a known-blocked agent stops nagging.

## Phase 3 — Settings UI

`Settings { EmptyView() }` is a placeholder; the app has no preference surface despite `NotchHUDConfig` supporting it.

1. **Settings window** — replace `EmptyView()` with a real `Form` (SwiftUI Settings scene): capture interval, capture on/off, sounds on/off + volume, TTLs (auto-clear, sticky approval), test-alert button (reuse `publishForTesting`, promote out of `#if DEBUG` as "Send test notification").
2. **Onboarding** — first-launch sheet: explain the island, the menu bar item, and how to install the herdr plugin hook (`herdr plugin link`).
3. **Config plumbing** — `NotchHUDConfig` is `@MainActor` + `UserDefaults`; make settings changes hot-apply (poll interval, TTLs already re-read per tick; verify sound changes take effect immediately).

## Phase 4 — Event pipeline reliability

The dual-source pipeline works but has latency and duplication characteristics worth tightening.

1. **Direct herdr socket adapter** — replace the per-poll CLI subprocess with a persistent connection (herdr's unix socket, protocol 17 JSON) for push-style updates: instant transitions, no 2s latency, no process spawn cost. Keep the CLI fallback for environments where the socket isn't reachable.
2. **Event-file writer** — the adapter currently appends JSONL via a plugin subprocess; if herdr ever delivers richer payloads (e.g., `state_labels` with timestamps), persist them and replay on launch so history survives restarts.
3. **Clock/ordering** — events from two sources can interleave; define a single logical clock (monotonic seq from herdr + file mtime) so "stale" file events never override fresher poll state.
4. **Failure modes** — herdr CLI hung → `waitUntilExit` blocks the main actor (already synchronous on `listAgents`); move all subprocess I/O off the main actor with timeouts (e.g., 5s) and mark the source "degraded" in the roster instead of blocking the UI.

## Phase 5 — Distribution

1. **Code signing** — Developer ID signing for the release build; currently ad-hoc. CI release layer should sign (key in repo secrets).
2. **Notarization** — `notarytool` + stapling in CI (ARCHITECTURE.md already lists this as the target); `.dmg` or `.zip` artifact upload per release.
3. **Auto-update** — Sparkle for the installed agent binary, or a simple self-update via `gh release` (download + `launchctl` swap); decide after notarization.
4. **Homebrew cask** — `brew install --cask bantay-tui` once notarized (documented as the future path in ARCHITECTURE.md).
5. **setup.sh polish** — verify idempotency across upgrades (already copies over the running binary; add "agent running → restart after install" handling and a `--uninstall` flag).

## Phase 6 — Testing & CI

1. **LogicCheck in CI** — add a CI layer that compiles and runs `.kilo/LogicCheck.swift` (the harness that works without XCTest); it catches what the XCTest suite duplicates, and it's the only check runnable on Linux/CLT.
2. **UI smoke test** — a headless launch + window-server assertion (window exists, correct size, centered) on `macos-15`, similar to the `swiftc`/`CGWindowList` probe used during the rebuild.
3. **Test the release path locally** — `swift build -c release` should be part of the dev loop (it caught the `#if DEBUG` `testAlert` regression that shipped in PR #3's first push).
4. **Dependabot hygiene** — two open PRs (actions/checkout 5→7, gitleaks 2.3.9→3.0.0). Both must keep SHA pins (Layer 5 enforces); bump deliberately and let the pins layer validate.
5. **Signing check in CI** — assert commits are SSH-verified (repo already requires it) and add a release-artifact signature check after Phase 5.

## Phase 7 — Observability

1. **Structured logging** — `bantay.log`/`bantay.err` are currently near-silent; add timestamped lines for: window created, poll success/failure, event transitions, sound plays, panel placement (with screen geometry).
2. **Diagnostics menu** — menu bar → "Diagnostics": current roster JSON, last poll latency, last event, window frame; useful for user bug reports.

## Non-Goals

- Electron or web-tech rewrite (native Swift, per ARCHITECTURE.md)
- General notification center replacement (only herdr agent events)
- iOS/iPadOS ports
- Multi-user or remote herdr connections (single-machine herdr socket only)

## Suggested Ordering

| Milestone | Contains | Exit criterion |
|---|---|---|
| M1 · Hardened core | Phase 1 + Phase 6.1 | 10-agent roster, multi-screen, no sound spam; LogicCheck in CI |
| M2 · Interactive | Phase 2 + Phase 3 | Row actions, settings window, a11y pass |
| M3 · Reliable pipeline | Phase 4 + Phase 7 | Socket adapter, no main-actor blocking, diagnostics menu |
| M4 · Shippable | Phase 5 + Phase 6.5 | Signed, notarized DMG with auto-update |

## Risks

- **herdr socket protocol drift** — protocol 17 verified today; pin to a herdr version in docs and make the socket adapter fail back to CLI.
- **Notchly-style morphs on non-notch displays** — visual QA on external monitors needed before M2.
- **Release signing friction** — Developer ID + notarization adds CI secrets and macOS approval flows; budget time in M4.
- **Test gap** — no local XCTest (CommandLineTools only); LogicCheck layer is the mitigation and must stay in sync with the XCTest suite.
