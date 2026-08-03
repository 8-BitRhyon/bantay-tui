# Plan 011 — Standalone agent detection (no multiplexer required)

Status: done (commit `5eef84a`, signed `security-signing@monozen.local`).

## Goal
Phase 1 of the competitive gap roadmap: Bantay must detect and surface
every coding agent — Claude Code, Codex, Gemini, Cursor, opencode —
even when they run in plain terminals with no herdr/tmux/zellij wrapper.

## Competitive context (research provided)
Biggest adoption blocker was "requires herdr". Competitors (Vibe Island,
AgentNotch, Notchcode) auto-detect standalone CLIs. Rate gauges, SSH
bridge, file shelf, multi-monitor, and Homebrew cask remain open phases.

## What changed
- `AgentDetector.swift` (new):
  - `canonicalName(forProcess:)` — claude/codex/gemini/cursor/opencode,
    case-insensitive.
  - `isHerdrManaged(environmentLines:)` — skips herdr-owned processes so
    they are never double-reported.
  - `transcriptSearchPaths(home:name:)` — per-agent transcript roots
    (`~/.claude/projects`, `~/.codex/sessions`, `~/.gemini/sessions`,
    `~/.cursor-agent`).
  - `latestActivity(root:)` — newest jsonl under the root, tail read,
    single-line 160-char snippet.
  - `StandaloneAgentScanner` — pure `detect(samples:home:)` (testable)
    + live `runningProcesses()` via `ps -axo pid=,comm=`.
- `AgentEventManager.mergeStandalone(into:detected:)` — appends detected
  agents to the herdr roster, skipping names herdr already manages;
  used by `refreshRosterAndArmWaits` when `standaloneScanEnabled`.
- `NotchHUDConfig.standaloneScanEnabled` (default on) + Settings toggle
  under Capture ("Scan standalone agents").
- ci.yml harness list includes `AgentDetector.swift`.

## Gates
- `swift format lint --recursive --strict Sources Tests` — clean.
- `swift build` + `swift build -c release` — 0 warnings.
- Harness — RED-first L9 (classification, env filtering, transcript
  tailing, scanner merge, toggle persistence), `ALL PASS`.
- Installed + `launchctl kickstart -k` — island visible, no crash.

## Next phases
- Rate-limit/usage gauge (local transcript `usage` fields).
- SSH bridge for remote devboxes.
- File shelf / clipboard tab.
- Multi-monitor floating pill.
- Homebrew cask distribution.