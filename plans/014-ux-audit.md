# Plan 014 — UI/UX audit: best-in-class glanceable agent control plane

Status: proposed. Audit + prioritized fixes. No code lands without its RED test
(see `plans/006-test-harness-sdd.md`); the adversarial corpus grows with every
fix.

## Why this matters

The product promise is "supervise and steer agents from anywhere on the desktop
**without switching to a terminal**." A full read of the source
(`NotchStatusView.swift`, `AgentEventManager.swift`, `HerdrSocketAdapter.swift`,
`IslandMetrics.swift`) plus a two-track competitive study (multi-agent
dashboards: Conductor, Cursor 2.0, Codex cloud, Jules, Devin, Warp, Vibe Kanban,
Claude Squad, Claude Code hooks; and notch/HUD apps: NotchNook, BoringNotch,
MediaMate + Apple HIG Live Activities / menu-bar / Feedback) shows the app is
**feature-complete but does not yet deliver that promise**: you can see *that*
agents exist and approve prompts, but you cannot see *what they are doing*, and
several interactions are actively harmful (blocking the UI on every click,
jumpy re-renders, ambiguous status colors, missed completions).

This plan is the "what to fix, in what order" ledger. Each item cites the
grounding evidence.

## Evidence base

- **Source facts** (file:line): every action routes through
  `HerdrSocketAdapter.runHerdr` which calls `Process.waitUntilExit()`
  synchronously (`HerdrSocketAdapter.swift:52-69`, `:91-111`). The class is a
  plain `final class` with no actor isolation, so `adapter.approve(paneId:)`
  invoked from a SwiftUI `Button` action **blocks the main actor for up to 1s**
  per `HerdrSocketAdapter.swift:72,87`. The single most important interaction
  (approve) freezes the island on every press.
- `captureTail` (`HerdrSocketAdapter.swift:200-204`) is fully implemented with
  zero call sites — the "peek at what the agent is doing" feature the whole
  product is about is not wired to the UI.
- `HerdrAgentInfo` decodes only 5 of 13+ fields the live `herdr agent list`
  JSON carries (`cwd`, `display_agent`, `focused`, session id, branch-ish are
  discarded) — `HerdrSocketAdapter.swift:219-233`.
- Status colors collide: `accessRequest` and `failed` are both `#ff6b6b`;
  `waiting` and `idle`/`cancelled` share hue families (`AgentEventKind.swift:42-53`).
- The global 1s `now` `Timer` (`NotchStatusView.swift:240-245`) re-publishes
  `now` unconditionally every second, recomputing the entire body (animations
  re-evaluate) even when collapsed/idle — churn + battery.
- No `accessibilityLabel`/`accessibilityValue` anywhere (grep: 0 hits); ~20
  text runs at opacity ≤ 0.5 (low contrast).
- Completion events auto-clear in 3s (`NotchStatusView.swift` via
  `autoClearTTL`) with no "while you were away" surface.
- Competitive patterns: (1) diff stats `+N/−M` as the glanceable "did work
  happen" meter (Codex cloud, Conductor); (2) "Needs input" outranks everything
  and is the only red (Codex Pets, Warp); (3) hover-for-metadata without context
  switch / watch-and-take-over (Conductor, Devin); (4) the list is a navigation
  surface — one click deep-links into the session (Warp); (5) filters shaped
  like triage: "everything that needs me" (Warp); (6) status must never silently
  disappear — explicit occlusion/fallback indicator (Tailscale, HIG menu-bar);
  (7) click-to-pin + hover-intent dwell, never default-hover mouse-traps
  (NotchNook vs BoringNotch bugs); (8) render only on real change, animations
  ≤2s, reduced-motion (HIG Live Activities).

## Ranked findings → fixes

### P0 — Correctness / trust (do first)

- **F1: Approve/deny/choice/stop block the main thread (freezes island).**
  Fire every adapter action on a detached task (the adapter's I/O is already
  synchronous/blocking); never await on the main actor. Add a `resolvingPanes`
  set in `AgentEventManager` + `markResolving(paneId:)`; queue cards show a
  resolving state (disabled, faint) and drop optimistically once marked — no
  more double-click "did it work?" and no more 1s freeze. Acceptance: clicking
  Approve yields zero `RunLoop` stall and the card clears before the next poll.
- **F2: Accidental double-approve via global hotkey.** `ShortcutKeyPressModifier`
  (`NotchStatusView.swift:381-396`) handles Y/N/digits with no `composingPaneId`
  guard; the macOS 13 monitor already guards it (`:328-340`). Add the
  guard + `resolvingPanes` check so a key press can't re-fire on a pane mid-action.

### P1 — Deliver the core promise (see without the terminal)

- **F3: Live peek.** Wire `captureTail` to a hover/click peek: per queue card and
  per roster row, on hover (or a ▸ affordance) fetch `pane read --source recent
  --lines N` and render a 2–4 line monospaced tail in the card. This is the
  single biggest UX win — it is literally "see what the agent is doing" inline.
  Throttle to the poll cadence; cancel in-flight on hover-out.
- **F4: Agent identity = project + branch, not the bare tool name.** Decode
  `cwd`/`display_agent` from the herdr poll (`HerdrAgentInfo` coding keys) and
  show `project` (basename of cwd) + `branch` (from `git` or `display_agent`)
  as the row's primary label; keep `source` (claude/codex) as a small tag.
  Four Claude agents stop looking identical. Roadmap already names this (M3.3).
- **F5: "Did work happen?" meter.** For herdr agents, run `git diff --shortstat`
  in `cwd` on demand and show `+N −M` in the row (Codex/Conductor pattern).
  Falls back to hidden when cwd unknown.

### P2 — Glanceability & reduced fatigue

- **F6: Disambiguate status colors.** `accessRequest/needs-input` → solid red
  (the only alarm), `failed` → amber-red `#ff9f43`, `waiting/blocked` → amber
  `#ffe066`, `progress` → teal/violet, `completed` → green, `idle/cancelled` →
  grey. Update `AgentEventKind.color` + `expandedGroupRank` ordering.
- **F7: Section headers in the expanded roster.** Label each group
  ("Needs you · 2", "Working · 3", "Done · 1", "Failed · 1") so the
  actionability ordering is legible, not just a color-dot list.
- **F8: "Attention only" filter.** A third tab/filter (beside Agents/Shelf) that
  shows only `needsInput` + `failed` — the Warp "everything that needs me" triage
  view. Default-off toggle in `NotchHUDConfig`.
- **F9: Completion "while you were away".** Keep a small recents strip / unread
  badge for `completed`/`failed` that arrived while collapsed; clear on expand.
  Replaces the "poof in 3s, never knew" gap.

### P3 — Motion / churn / a11y (polish per make-interfaces-feel-better)

- **F10: Gate the 1s `now` tick.** Only publish `now` while expanded AND
  `showElapsedTime` on, or while an approval's resolving state is live. Stops the
  whole-body recompute every second when idle (HIG "render only on real change").
- **F11: Hover-intent + click-to-pin.** Increase hover-expand dwell to ~250ms
  (already 0.22) and add an exit grace period + click-to-pin so the panel does
  not collapse the moment the cursor drifts. Already island-scoped hover (good);
  add pin state.
- **F12: Accessibility.** Add `accessibilityLabel`/`accessibilityValue` to every
  interactive control and status row (VoiceOver + hover a11y). Raise the lowest
  text opacities (the ~20 runs ≤0.5) to ≥0.6 for contrast, or use `.secondary`
  which adapts.
- **F13: Stable layout.** Avoid animating height on every agent add/remove; use
  `.animation` only on `isExpanded`, and reserve a min roster area so rows don't
  jitter. Tabular-nums on all live counts/elapsed.

### P4 — Latency / reliability

- **F14: Use the herdr socket for actions.** `agent.send_keys` / `agent.focus`
  are verified sub-millisecond over `~/.config/herdr/herdr.sock`
  (`HerdrSocketClient.swift` already supports arbitrary NDJSON). Move
  approve/deny/choice/focus off the per-call `Process` spawn to the socket for
  near-instant feedback (complements F1).

## Acceptance bar (mirrors 000 baseline)

A user can (a) see what every agent is actively doing from the notch, (b) answer
any approval with one click that feels instant and cannot double-fire, (c) tell
at a glance what needs them vs what's done, and (d) never miss a completion —
all without opening a terminal.

## Gates

- `swift format lint --recursive --strict Sources Tests` — clean.
- `swift build` (debug + release) — 0 warnings.
- RED→GREEN harness blocks for F1 (stall + double-fire), F3 (peek fetch),
  F6 (color map), F7 (headers), F8 (filter) appended to `.kilo/LogicCheck.swift`.
- Manual: `launchctl kickstart -k gui/$(id -u)/com.bantay-tui.agent`; island
  visible, approve feels instant, peek shows live output, no 1s freeze.

## Note on scope

F1, F2, F3, F6, F7, F8, F10, F11, F12 are the recommended first implementation
wave (highest trust + promise payoff, lowest risk). F4/F5/F14 are the second
wave (richer data, latency). F9/F13 round it out.

## Status (as implemented)

- **Wave 1 (shipped):** F1 (async + optimistic dismiss of approval/stop actions,
  `resolvingPanes` in `AgentEventManager`, detached `performAction` so the
  island no longer blocks on `waitUntilExit`), F2 (global-hotkey guard for
  `composing`/`resolving`), F3 (live `captureTail` peek on approval-card hover),
  F6 (disambiguated status colors), F7 (section headers in grouped roster),
  F10 (gated 1s `now` tick), F12 (accessibility labels/values).
- **Wave 2 (shipped):** F4 (decode `cwd` from herdr poll; roster rows now lead
  with `project · branch` via `ProjectContext`, not a bare tool name), F5
  (`git diff --shortstat` `+N −M` meter fetched per row, `diffStats`), F14
  (route `sendKeys` / `focusPane` / `captureTail` over the herdr socket with CLI
  fallback — sub-ms vs ~100ms Process spawn; `socketCall` + `HerdrSocketClient.perform`).
- **Not yet built:** F8 (Attention-only filter), F9 (completion recents /
  "while you were away"), F11 (click-to-pin + hover grace), F13 (stable layout /
  no-jitter on add-remove).
