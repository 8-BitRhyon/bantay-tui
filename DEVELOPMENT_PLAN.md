# Bantay-TUI Development Plan

Roadmap for taking the notch control plane from working prototype to a polished, reliable, distributable macOS app. Tracks against the current architecture ([ARCHITECTURE.md](ARCHITECTURE.md)).

## Current State

| Area | Status |
|---|---|
| Island | Full control plane: idle agent strip beside the notch (names/dots/summary, density pin, menu-bar clearance) + expanded panel (counts header, pinned approval queue, state-grouped roster, shelf tab, usage-gauge footer) |
| Approvals | In-UI execution of yes/no, numbered choices, and multi-select — no terminal needed; approval heartbeat kills phantom prompts |
| Pipeline | Three sources: herdr poll, standalone process scan (any CLI, no multiplexer), event file + SSH remote ingest; usage aggregation from transcripts |
| Speed & polish | Global `⌥Space`, `Y/N/1-9` roster keys, edge-glow, menu-bar badge, copy actions, snooze presets, elapsed timers, sound preview |
| Hard problems | Full-screen/spaces re-anchor, menu-bar collision avoidance, display hot-swap ghost re-anchor, terminal-agnostic focus (5-terminal registry) |
| Logic core | Pure `IslandMetrics`/pipeline functions; `.kilo/LogicCheck.swift` harness L1–L18 (runs without XCTest) + CI XCTest suite |
| CI | 5 layers / 7 jobs (format → compile → tests → logic checks → release + secrets + pins), all green; `main` protected (PR + checks + signed commits) |
| Distribution | `scripts/setup.sh` (install / `--uninstall` / `--package` → release zip); Homebrew cask formula ready; notarization pending |

## Vision

The notch becomes the primary, glanceable surface for agentic work: one glance shows every agent and what it needs; one click approves, prompts, or focuses — from anywhere on the desktop, regardless of terminal or multiplexer.

## Done (committed history)

- **Idle UI**: live agent strip beside the notch, three styles, density pin, pure geometry (`IslandMetrics`).
- **Expanded control plane**: counts header, pinned approval queue, state-grouped roster, footer health bar.
- **Inline approvals**: yes/no, numbered choices, multi-select toggle+submit; `ApprovalControls` model; approval data merged from the event stream.
- **Speed snacks**: global hotkey, keyboard shortcuts, edge-glow, menu-bar badge, copy menus, snooze presets, elapsed timers, sound preview.
- **Universal detection**: standalone process scan + transcript tailing (no multiplexer required), herdr-managed dedupe.
- **Roadmap phases**: usage/rate gauge, SSH remote ingest, file shelf + clipboard tab, multi-monitor + floating pill, Homebrew cask packaging.
- **Hard challenges**: approval heartbeat (phantom prompts), full-screen/space transitions, menu-bar collision avoidance, display hot-swap re-anchor, terminal-agnostic focus.
- **Beachball fix**: `ps` pipe deadlock (drain-before-wait) + heavy scans off the main actor.

## Remaining work

### M1 · Distribution hardening (next)

1. **Notarization + Developer ID** — sign the release build and staple via `notarytool`; wire into CI release layer (secrets + keychain).
2. **Homebrew cask release** — first tagged release fills the cask `sha256`/`url`; verify `brew install --cask` end-to-end.
3. **Auto-update** — Sparkle or `gh release` self-update with `launchctl` swap; decide after notarization.

### M2 · Multiplexer adapters

1. **tmux adapter** behind `PlexerAdapter` — `list-panes -a -F`, `capture-pane -S -N`, `select-pane`/`switch-client`, `send-keys`; detection via `TMUX` env / socket.
2. **zellij adapter** — `zellij action` verbs, session listing, dump-screen.
3. **Process-level pane focus** — PID/TTY → terminal window activation for standalone agents (OSC 7/9 where supported).

### M3 · Deeper control plane

1. **Peek panel** — per-queue-card live output tail via `captureTail` (already in the adapter protocol).
2. **Rate-limit projections** — surface API limits from provider headers when available, beyond the transcript gauge.
3. **Agent detail view** — cwd, workspace, session id, transcript peek; richer row context menus.
4. **Diagnostics menu** — roster JSON, poll latency, window frame, ingest status (for bug reports).

### M4 · UX & accessibility

1. **VoiceOver labels** for roster rows + approval controls; `accessibilityAction` on rows.
2. **Row-level snooze/mute** — silence a specific source for a window.
3. **Quiet-hours** window (visual-only mode).

## Risks

- **herdr protocol drift** — verbs verified against the installed herdr; keep the CLI adapter as fallback and pin the documented verbs in tests.
- **Notarization friction** — Developer ID + stapling adds CI secrets and approval flows; budget time in M1.
- **Test gap** — no local XCTest (CommandLineTools only); the L1–L18 harness is the local gate and must stay in sync with the CI XCTest suite.
- **tmux/zellij verb drift** — version differences in formatting flags; keep the pure classification/geometry logic adapter-agnostic so adapters stay thin.
