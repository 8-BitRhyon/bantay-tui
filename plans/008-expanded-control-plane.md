# Plan 008 — Expanded control-plane UI + multiplexer-agnostic adapter

Status: done (commit `380a695`, signed `security-signing@monozen.local`).

## Goal
Turn the rudimentary expanded agent list into a full "agentic control
plane": supervise and steer AI agents from anywhere on the desktop without a
terminal window — and make the same UI drive any multiplexer (herdr today,
tmux/zellij later).

## Research (2 subagents, DeepSeek V4 Flash)
- Claude Code agent view / BoringNotch / Zellij / tmux / iTerm2 / macOS
  Control Center patterns → approval queue pinned top, state-grouped rows,
  one-click approve, peek, attach, health footer.
- tmux/zellij/herdr CLI + agent CLI resume verbs (`claude -r`, `codex exec
  resume --last`, `gemini -r latest`) and approval semantics → keystroke
  approvals only work against interactive TUI in a pane; headless approval is
  policy-level.
- herdr socket API confirmed: `pane run`, `pane read --source recent`,
  `agent send-keys` chords (`ctrl+c`), socket at `~/.config/herdr/herdr.sock`.

## What changed
- `IslandMetrics`: `AgentCounts` + `agentCounts`, `expandedGroupRank`,
  `queueSplit` (cap/overflow), queue-aware `expandedSize(queueCount:)` /
  `contentHeight`, `queueCardHeight`/`footerHeight`.
- `PlexerAdapter.swift` (new): `PlexerKind`, pure `PlexerDetection`
  (HERDR_ENV / herdr socket, TMUX env / socket, ZELLIJ env), `PlexerAdapter`
  protocol (listPanes, captureTail, focusPane, sendLine, sendKeys, approve,
  deny, stop, attachPane).
- `HerdrSocketAdapter`: conforms; `captureTail` (`pane read --source recent
  --lines N`), `sendLine` (`pane run`), `stop` (`send-keys ctrl+c`),
  `attachPane`.
- `NotchStatusView`: control-plane layout — counts header, pinned approval
  queue (capped, +N more), state-grouped roster with Stop hover action,
  footer health bar.
- `NotchHUDConfig`/`SettingsView`: expanded facets — queue pin toggle, group
  by state toggle, queue card cap (1–5), persisted.
- `.github/workflows/ci.yml`: harness file list includes `PlexerAdapter.swift`.

## Gates
- `swift format lint --recursive --strict Sources Tests` — clean.
- `swift build` + `swift build -c release` — 0 warnings.
- Harness — RED-first L6 (counts, queue split, ranks, queue-aware height,
  mux detection, facet persistence), `ALL PASS`.
- Installed + `launchctl kickstart -k` — island visible, no crash.

## Next
- tmux/zellij concrete adapters behind the protocol.
- Peek (captureTail) panel + number-key choices in the queue.
- Attach-to-GUI (AppleScript/`open -a Terminal`) for tmux/zellij.