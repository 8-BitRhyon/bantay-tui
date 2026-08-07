# Bantay-TUI Development Plan

Roadmap for taking the notch control plane from working prototype to a polished, reliable, distributable macOS app. Tracks against the current architecture ([ARCHITECTURE.md](ARCHITECTURE.md)).

## Current State

| Area | Status |
|---|---|
| Island | Full control plane: idle agent strip beside the notch (names/dots/summary, density pin, menu-bar clearance) + clean expanded panel (counts header, single-list roster with inline approvals, Recent section, shelf tab) |
| Approvals | In-UI execution of yes/no, numbered choices, and multi-select — no terminal needed; approval heartbeat kills phantom prompts |
| Pipeline | herdr push event stream (real-time) + standalone process scan (any CLI, no multiplexer) + event file / SSH remote ingest; usage aggregation from transcripts |
| Speed & polish | Global `⌥Space`, `Y/N/1-9` roster keys, edge-glow, menu-bar badge, copy actions, snooze presets, elapsed timers, sound preview |
| Notifications | ntfy.sh push (approvals/failures/completions), tmux status-bar integration, opt-in Notification Center when hidden |
| Hard problems | Full-screen/spaces re-anchor, menu-bar collision avoidance, display hot-swap ghost re-anchor, terminal-agnostic focus (5-terminal registry) |
| Logic core | Pure `IslandMetrics`/pipeline functions; `.kilo/LogicCheck.swift` harness L1–L58 (runs without XCTest) + CI XCTest suite |
| CI | 5 layers / 7 jobs (format → compile → tests → logic checks → release + secrets + pins), all green; `main` protected (PR + checks + signed commits) |
| Distribution | `scripts/setup.sh` (install / `--uninstall` / `--package` → release zip); Homebrew cask formula ready; notarization pending |

## Vision

The notch becomes the primary, glanceable surface for agentic work: one glance shows every agent and what it needs; one click approves, prompts, or focuses — from anywhere on the desktop, regardless of terminal or multiplexer.

## Done (committed history)

- **Idle UI**: live agent strip beside the notch, three styles, density pin, pure geometry (`IslandMetrics`).
- **Expanded control plane**: counts header, clean single-list roster with inline approvals (no queue cards), Recent section, no footer chrome.
- **Inline approvals**: yes/no, numbered choices, multi-select toggle+submit; `ApprovalControls` model; approval data merged from the event stream.
- **Speed snacks**: global hotkey, keyboard shortcuts, edge-glow, menu-bar badge, copy menus, snooze presets, elapsed timers, sound preview.
- **Universal detection**: standalone process scan + transcript tailing (no multiplexer required), herdr-managed dedupe.
- **Real-time push**: herdr `events.subscribe` stream drives the roster; poll loop is a safety net; per-pane wait processes removed.
- **Notifications**: ntfy.sh push topic, tmux status-bar helper, drop-files-on-notch shelf.
- **Claude Code hooks**: `PermissionRequest`, `Notification`, `StopFailure` alongside the legacy `PermissionPrompt`.
- **Roadmap phases**: usage/rate gauge, SSH remote ingest, file shelf + clipboard tab, multi-monitor + floating pill, Homebrew cask packaging.
- **Hard challenges**: approval heartbeat (phantom prompts), full-screen/space transitions, menu-bar collision avoidance, display hot-swap re-anchor, terminal-agnostic focus.
- **Beachball fix**: `ps` pipe deadlock (drain-before-wait) + heavy scans off the main actor.

## Remaining work

> **Superseded by [plan 019](plans/019-fresh-roadmap.md)** (independent audit,
> 2026-08-06). The reframe: the Mac app must become genuinely usable first
> (borrowing BoringNotch/NotchDrop/DynamicNotchKit polish), then mobile-first
> is the flagship priority (don't unlock the Mac to see/act), then
> differentiation from Claude Code's chat (cross-agent timeline, spend
> guardrails, ambient awareness). Follow plan 019's Phase 0 (make the
> baseline true — CI is red on the in-flight branch) → A → B → C.

### M1 · Distribution hardening (a one-time event, not a phase)

1. **First tagged release (v0.2.0)** — build release zip, fill the cask `sha256`/`url`, trigger the release workflow, document Gatekeeper bypass. Notarization/Developer ID is already scripted in `scripts/setup.sh`.
2. **Auto-update (Sparkle)** — deferred to plan 019 B4 (only pays off once there's a tagged release + users who can't rebuild).
3. **Homebrew cask release** — filled by the tag above; verify `brew install --cask` end-to-end.

### M2 · Multiplexer adapters — SHIPPED, but not wired

`TmuxAdapter`, `ZellijAdapter`, `PaneFocusRouter`, `ControlGateway`, `HookSdk`,
and the Go TUI all exist and are harness-tested. The missing piece is the
`AdapterProvider` seam plan 017 WI-4 specified but never built: the runtime
still hardcodes `HerdrSocketAdapter` in three places. See plan 019 Phase 0 /
A4 (menu-bar mirror also needs the active-adapter concept).

### M3 · Deeper control plane — mostly shipped

Peek panel, project·branch identity, diff meter, and rate signal landed in
016/017. Open items are tracked in plan 019: multi-agent timeline (A3),
spend history + budget alerts (A5), session resume (B3), digest (B5).

### M4 · UX & accessibility — mostly shipped

Snooze/mute/quiet hours, a11y labels, and pin persistence are done. Remaining
polish is tracked under plan 019's Phases A–C.

## Risks

- **herdr protocol drift** — verbs verified against the installed herdr; keep the CLI adapter as fallback and pin the documented verbs in tests. **Plan 019 0.2** adds the missing wire fixture for the push stream (dot vs underscore event spelling).
- **Notarization friction** — Developer ID + stapling adds CI secrets and approval flows; budget time in M1 / plan 019 A1.
- **Test gap** — no local XCTest (CommandLineTools only); the harness is the local gate and must stay in sync with the CI XCTest suite. Harness compile lists in `ci.yml` must include every new source file (currently omits `HerdrEventStream.swift`/`AgentAlertNotifier.swift` — CI is red on the in-flight branch; plan 019 0.1).
- **tmux/zellij verb drift** — version differences in formatting flags; keep the pure classification/geometry logic adapter-agnostic so adapters stay thin.
