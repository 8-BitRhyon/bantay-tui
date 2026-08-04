# Bantay-TUI — UI/UX Audit Findings

> Standalone findings document distilled from a full read of the source, a
> two-track competitive study, and Apple HIG review. No code changes are
> described here — only what was found and why it matters. The companion
> implementation plan is `plans/014-ux-audit.md`.

## 1. Scope & method

- **Source read (every UI/data path):** `NotchStatusView.swift` (1,537 LOC),
  `IslandMetrics.swift` (666), `AgentEventManager.swift`, `AgentEventKind.swift`,
  `HerdrSocketAdapter.swift`, `HerdrSocketClient.swift`, `PlexerAdapter.swift`,
  `DynamicIslandApp.swift`, `SettingsView.swift`, `NotchHUDConfig.swift`,
  `UsageTracker.swift`.
- **Competitive study A — multi-agent dashboards:** Conductor, Cursor 2.0,
  OpenAI Codex cloud, Google Jules, Devin, Warp 2.0 Agent Management, Vibe
  Kanban, Terragon, Sculptor, Claude Squad, and Anthropic Claude Code hooks.
- **Competitive study B — notch / HUD apps + HIG:** NotchNook, BoringNotch,
  MediaMate (plus dead/unverifiable: Notchly, alcove, Peninsula), and Apple
  HIG for Live Activities, the menu bar, Feedback, and Managing Notifications.
- **Plumbing probe:** live `herdr agent list` / socket behavior.

## 2. The core promise vs. reality

The product's stated promise is to **supervise and steer AI coding agents from
anywhere on the desktop without switching to a terminal**. The audit found the
app is feature-complete but does **not yet deliver that promise**: a user can
see *that* agents exist and approve prompts, but cannot see *what they are
doing*, and several interactions are actively harmful.

## 3. Critical findings (correctness / trust)

### 3.1 Every approval/stop action froze the island
All agent actions route through `HerdrSocketAdapter.runHerdr`, which calls
`Process.waitUntilExit()` **synchronously**. The adapter is a plain `final
class` with no actor isolation, so `adapter.approve(paneId:)` invoked from a
SwiftUI `Button` action **blocks the main actor for up to 1 second**
(`HerdrSocketAdapter.swift:52-69`, `:91-111`). The single most important
interaction — approving a prompt — freezes the entire island on every press.

### 3.2 Accidental double-approve
Because the press blocks and there is no optimistic feedback, a user clicks
again ("did it work?"), firing the same `y`+Enter twice. The macOS 14+
keyboard modifier (`ShortcutKeyPressModifier`, `NotchStatusView.swift:381-396`)
handled Y/N/digits with **no `composingPaneId` guard** (the macOS 13 monitor
did guard it), so a key press could also re-fire.

### 3.3 The "see what the agent is doing" feature was built but never wired
`captureTail` (`HerdrSocketAdapter.swift:200-204`) is fully implemented with
**zero call sites**. The literal core promise of the product — an inline peek
at live agent output — did not exist in the UI.

### 3.4 Richer per-agent data was collected but discarded
`HerdrAgentInfo` decoded only 5 of 13+ fields the live `herdr agent list` JSON
carries. `cwd`, `display_agent`, `focused`, session id, and branch-ish
information were dropped (`HerdrSocketAdapter.swift:219-233`). The herdr socket
exposes `agent.read` / `agent.send_keys` / `agent.focus` at sub-millisecond
latency, but the app used the socket only for `agent.list` and spawned a fresh
`Process` for every other action.

## 4. Glanceability findings

### 4.1 Status colors collide
In `AgentEventKind.color`, `accessRequest` and `failed` are **both `#ff6b6b`**;
`waiting` shares a hue family with `idle`/`cancelled`. A user cannot tell at a
glance whether something "needs me now" (red) versus "failed" (should be
distinct) versus "blocked/working" (amber/violet).

### 4.2 Agent identity is just the tool name
Roster rows showed only `source` ("claude", "codex", …). Four Claude agents
look identical. There is no project or branch, so the user cannot tell *which*
repo each agent is in.

### 4.3 No "did work happen?" signal
No diff stat (`+N −M`) or file-change indicator anywhere, despite the data
being cheaply available (`git diff --shortstat` in the agent's `cwd`).

### 4.4 The expanded roster has no structure
State-grouped rows existed (rank 0-4) but with **no section headers** — the
actionability ordering (Needs you → Working → Done → Failed → Idle) was
invisible; only a color dot hinted at it.

### 4.5 Completions vanish silently
`autoClearTTL` (3s default) clears `completed`/`failed` events quickly. If the
user steps away, there is no "while you were away" surface — they never learn
what finished.

## 5. Motion / churn / accessibility findings

### 5.1 The whole body recomputed every second
A global 1s `Timer` published `now` unconditionally (`NotchStatusView.swift:
240-245`), recomputing the entire view body (and re-evaluating animations)
every second even when collapsed and idle — battery + jank, against HIG
"render only on real change".

### 5.2 No accessibility
Grep found **zero** `accessibilityLabel` / `accessibilityValue` / `accessibilityHint`
usages. ~20 text runs used opacity ≤ 0.5 (low contrast against the black
island). The control plane was effectively invisible to VoiceOver.

### 5.3 Layout can jitter
The island height and content resize as agents appear/disappear during the 2s
poll; chip widths vary by name length; the `now` tick fed live counters without
tabular-nums. No "Attention only" triage filter existed for when many agents run.

## 6. What the best products do (evidence)

### 6.1 Multi-agent dashboards
- **Four-state status set** — `Running / Needs input / Ready / Blocked`
  (Codex Pets), or Warp's `Working / Blocked / Canceled / Failed / Success`.
  Everything else is noise.
- **"Needs input" outranks everything** — show the agent needing approval
  first, then blocked, then ready, then running (Codex Pets).
- **Diff stats `+N −M` as the glanceable "did work happen" meter** — Codex
  cloud and Conductor both put it in the row.
- **Identity = repo · branch** — Codex shows `repo · branch`; Conductor/Sculptor
  give each agent its own branch/worktree.
- **Relative elapsed time, thresholds** — Codex "2m"; Warp omits duration for
  interactive runs.
- **List is a navigation surface** — one click deep-links into the full session
  (Warp).
- **Hover for metadata without context switch / watch-and-take-over** —
  Conductor hover preview; Devin's embedded Shell/IDE/Browser.
- **Filters shaped like triage** — Warp's "everything that failed today" /
  "runs from Slack" → the notch equivalent is an "Attention only" view.
- **State must never silently disappear** — Tailscale's `occlusionState`
  indicator; HIG warns not to rely on menu-bar presence.
- **Risk explanation on demand** — Claude Code's `Ctrl+E` Low/Med/High, not
  always-on.

### 6.2 Notch / HUD apps + HIG
- **Collapsed = black pill hugging the notch**; one glanceable datum, never a
  list; visually inert (no idle animation) — HIG Live Activities.
- **Click-to-pin + hover-intent dwell, never default-hover mouse-traps** —
  NotchNook's click/swipe default vs. BoringNotch's default-hover, which
  generated "clicking sound while hovering", "stuck fullscreen bar", and
  "cursor lost in notch" bugs.
- **Never steal focus / warp the cursor / claim clicks outside bounds** —
  BoringNotch's trackpad-click bug is the cautionary tale.
- **Animations ≤ 2s, move existing elements rather than recreate, reduced-
  motion honored** — HIG.
- **Render only on real change; escalate deliberately** (collapsed → expanded →
  banner → alert) — Feedback + Managing Notifications HIG.
- **Single-modifier or keyboard path to force-open** (⌥-click / global hotkey)
  independent of the mouse — HIG menu-bar dynamic items.

## 7. Ranked recommendation summary

| # | Finding | Severity | Fix direction |
|---|---------|----------|---------------|
| F1 | Actions block main thread (freeze + double-approve) | P0 | Fire actions on detached task; optimistic dismiss |
| F2 | Hotkey can double-fire while composing | P0 | Guard with `composing`/`resolving` |
| F3 | Live peek (`captureTail`) never wired | P1 | Hover/click peek of agent output |
| F4 | Identity = tool name only | P1 | Decode `cwd`; show `project · branch` |
| F5 | No "did work happen" signal | P1 | Per-row `git diff --shortstat` `+N −M` |
| F6 | Status colors collide | P2 | Distinct hue per state |
| F7 | No roster section headers | P2 | Label groups (Needs you / Working / …) |
| F8 | No triage filter | P2 | "Attention only" view |
| F9 | Completions vanish silently | P2 | "While you were away" recents |
| F10 | 1s tick recomputes body | P3 | Gate `now` to visible-elapsed/peek |
| F11 | Hover mouse-trap risk | P3 | Hover-intent + click-to-pin + exit grace |
| F12 | No accessibility / low contrast | P3 | `accessibilityLabel`/`Value`; raise contrast |
| F13 | Layout jitter | P3 | Stable layout; tabular-nums |
| F14 | Actions use slow CLI not socket | P4 | Route over herdr socket (sub-ms) |

## 8. Acceptance bar (what "good" looks like)

A user can (a) see what every agent is actively doing from the notch, (b)
answer any approval with one click that feels instant and cannot double-fire,
(c) tell at a glance what needs them vs. what's done, and (d) never miss a
completion — all without opening a terminal.
