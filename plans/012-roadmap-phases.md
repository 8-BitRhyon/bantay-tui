# Plan 012 — Remaining roadmap phases (usage gauge, SSH bridge, shelf, multi-monitor, cask)

Status: done. Commits (all signed `security-signing@monozen.local`):
- `2181b50` Phase 2 — usage & rate gauge
- `343e157` Phase 3 — remote ingest over SSH
- `31157fb` Phase 5 — file shelf + clipboard history
- `1967a9c` Phase 4 — multi-monitor + floating pill
- `779a5ca` Phase 6 — Homebrew cask + packaging

## What shipped (TDD: RED-first harness block per phase)

### Phase 2 — Usage & rate gauge (`UsageTracker.swift`, L10)
- Parses token/cost usage from Claude Code and Codex transcript JSONL
  (message-nested + flat/rollout shapes); aggregates newest transcripts per
  agent family; budget fraction (amber ≥70%, red ≥90%); compact token
  formatting (`1.2k`, `3.5m`).
- Footer gauge: cost + token totals + budget bar. `showUsageGauge` (default
  on), `usageBudgetUSD` (clamped 1–100) + Settings controls.

### Phase 3 — SSH remote bridge (`EventIngestServer.swift`, L11)
- Localhost-only NWListener; strict HTTP POST parsing (Content-Length
  required, truncated/non-POST rejected).
- `ingestEventLine` validates with the payload decoder then appends to the
  watched `agent-events.jsonl` — remote events flow through the same
  pipeline as local. `ingestEnabled` (default OFF — secure) + `ingestPort`
  (default 41817, clamped 1024–65535); Settings section with `ssh -R` hint.

### Phase 5 — Shelf (`ShelfModel.swift`, L13)
- Clipboard history: whitespace ignored, content-dedup moves to front,
  capped; polled from the system pasteboard each second.
- File drops via `dropDestination`: dedup by URL, newest first, open/remove.
- Agents/Shelf tab bar in the expanded island. `showShelfTab` (default on),
  `shelfLimit` (clamped 1–50).

### Phase 4 — Multi-monitor (`IslandMetrics` ScreenInfo/islandScreen, L12)
- Screen selection: mouse-notch > any notch > mouse (floating).
- Floating pill geometry (centered below the menu bar) for external
  displays/clamshell. `followMouseScreen` + `floatingPillOnNoNotch` (both
  default on); Settings "Displays" section.

### Phase 6 — Distribution (`scripts/setup.sh --package`, `Cask/`)
- Packages a release `.app` bundle + zip (`dist/bantay-tui.zip`); Homebrew
  cask formula with `zap` entries; sha256 placeholder for first tag.

## Gates (all phases)
- `swift format lint --recursive --strict Sources Tests` — clean.
- `swift build` + `swift build -c release` — 0 warnings.
- Harness — L10–L13 RED-first blocks, `ALL PASS` (L1–L13 total).
- Installed + `launchctl kickstart -k` after each phase — island visible.

## Next (the "other list")
- Notarization + Dev ID for the cask artifact.
- In-panel peek (captureTail) per queue card.
- tmux/zellij adapters behind `PlexerAdapter`.