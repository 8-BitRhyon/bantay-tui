# Bantay-TUI — Architecture

Native SwiftUI macOS app that turns the MacBook notch into an **agentic control plane**: live agent state, inline approval execution, and quick actions — across herdr, tmux, zellij, or standalone agent CLIs.

## Why

The terminal is where agents live but not where you always are. Bantay bridges the gap: the notch shows which agent is `blocked`, which needs `approval`, which just finished (`done`) — and lets you act (approve, choose, prompt, focus) without opening a terminal.

## Components

| Component | Role |
|---|---|
| `DynamicIslandApp.swift` | Main SwiftUI entry; `.accessory` app. Owns the island `NSPanel` (`fullScreenAuxiliary`/`canJoinAllSpaces`/`stationary`/`ignoresCycle`, top-level window level), the tray menu (roster, snooze presets, settings), the global `⌥Space` hotkey, the menu-bar badge timer, and display/full-screen/space observers with settle-delay re-anchoring |
| `AgentEventManager.swift` | MainActor pipeline: merges herdr poll + standalone scan into a roster, tails the events file, runs the approval heartbeat, aggregates usage, arms status-wait processes; publishes `agents`, `currentEvent`, `usage` |
| `AgentEventKind.swift` | Enum mapping agent states to event kinds (`idle` included for the roster); severity ordering |
| `IslandMetrics.swift` | Pure geometry & policy: idle strip widths (names/dots/summary), expanded control-plane metrics (`AgentCounts`, `queueSplit`, group ranks), `ApprovalControls`, `ApprovalHeartbeat`, `FullScreenPolicy`, `MenuBarClearance`, `DisplayAnchor`, multi-monitor `ScreenInfo`/`islandScreen`, floating-pill frames, `elapsedLabel`, shortcut-key mapping |
| `NotchStatusView.swift` | The island UI: idle agent strip, expanded control plane (approval queue with inline yes/no/choices/multi controls, state-grouped roster, shelf tab, footer with usage gauge), edge-glow, keyboard shortcuts, clipboard polling |
| `NotchHUDConfig.swift` | `UserDefaults` settings for every facet (see README table); clamps + persistence |
| `HerdrSocketAdapter.swift` | Runs the herdr CLI: `herdr agent list`, `herdr pane focus`, `herdr agent send-keys` (approve/deny/choices), `herdr agent wait`; conforms to `PlexerAdapter` |
| `PlexerAdapter.swift` | Multiplexer seam: `PlexerKind` + pure `PlexerDetection` (HERDR_ENV/socket, TMUX env/socket, ZELLIJ env) + the `PlexerAdapter` protocol (listPanes, captureTail, focusPane, sendLine, sendKeys, approve, deny, stop, attachPane) — tmux/zellij adapters plug in behind it |
| `AgentDetector.swift` | Standalone agent detection: process-name classification (claude/codex/gemini/cursor/opencode), herdr-managed env filtering, transcript discovery + newest-JSONL tailing for latest activity |
| `UsageTracker.swift` | Token/cost gauge: parses `usage`/`costUSD` from Claude Code and Codex transcripts, aggregates, budget fraction, compact formatting |
| `EventIngestServer.swift` | Localhost HTTP listener (NWListener) for remote events over SSH tunnels; strict POST parsing; appends validated payloads to the watched events file |
| `ShelfModel.swift` | Pure clipboard-history + shelf-file logic (dedup, ordering, limits) |
| `TerminalFocusser.swift` | Terminal-agnostic focus: ordered bundle-ID registry (Ghostty/Warp/WezTerm/Alacritty/iTerm2/Terminal/VSCode/IntelliJ) + app activation |
| `LaunchAgent.swift` | Launch-agent plist management |
| `SettingsView.swift` | Settings form (all facets), welcome/onboarding sheet |

## Event pipeline

Three sources feed the same manager:

1. **herdr poll** (default when herdr is present): `herdr agent list` every `captureInterval` seconds. Status mapping: `blocked → access_request`, `working → progress`, `running → started`, `idle → idle`, `done → completed`, `failed → failed`, `cancelled → cancelled`. Per source, the highest-severity agent wins; events emit only on state transitions; persistent blocked/working pills silently re-show while the state holds.
2. **Standalone scan** (default on, runs in a detached task): process classification + newest-transcript tailing. herdr-managed processes are skipped by env marker; agents herdr already reports are deduped by canonical name.
3. **Event file + remote ingest** (optional): `scripts/event-adapter.mjs` (herdr plugin `bantay-tui.integration`) appends JSONL to `~/Library/Application Support/Bantay-TUI/agent-events.jsonl`, which the manager tails for richer `state_labels`/`variance`/`choices`. The localhost ingest server (off by default) POSTs validated lines into the same file, so remote agents over `ssh -R` flow through the identical pipeline.

The manager publishes a merged roster (`agents`) and the latest event (`currentEvent`); `mergeApprovals` attaches decoded approval prompts (variance/choices) and working-burst start times to blocked rows.

## Approval execution

Approval prompts carry `variance` (`yes_no`/`choices`/`multi`) and `choices`. `IslandMetrics.ApprovalControls` is the pure model; the UI renders:

- yes/no → Approve/Deny (`y`/`n` + Enter via `herdr agent send-keys`)
- choices → numbered buttons (`<n>` + Enter)
- multi → toggle set + Submit (`1,3` + Enter)

The **approval heartbeat** (`IslandMetrics.ApprovalHeartbeat` + `heartbeatVerify`) re-verifies every pinned prompt against live agent status each poll: prompts stay only while the pane still reports blocked/unknown; working/done/idle/failed self-clear — killing phantom prompts from dropped hooks. Unknowns never phantom-clear.

## Reliability systems

| System | Mechanism |
|---|---|
| Full-screen & spaces | `didEnter/didExitFullScreen` + `activeSpaceDidChange` observers, debounced through a cancellable settle task (0.35 s) that re-shows/re-anchors per `showInFullScreen` |
| Menu-bar collisions | `MenuBarClearance` clamps the idle strip to `auxiliaryTopLeft/RightArea` widths (fallback screen-minus-notch) when `avoidMenuBarIcons` |
| Display hot-swap | `didChangeScreenParameters` + `screensDidWake` → `handleDisplayChange` → `reanchorIfGhosted()` (visible window off every screen gets moved back) + reposition |
| Terminal focus | `TerminalRegistry` resolves the running preferred terminal; `TerminalFocusser` activates it (opens Terminal as last resort) |
| Main-actor safety | `ps` scan, transcript enumeration, and usage aggregation run in `Task.detached`; process pipes drain before `waitUntilExit` |

## Click-to-focus & actions

- Row/card click → `herdr pane focus <paneId>` (herdr) or `TerminalFocusser` (any terminal).
- Per-row: Focus, Stop (`ctrl+c` via send-keys), Compose prompt.
- Queue cards: approve/deny/choice/submit + Force Focus Terminal + Retry.

## Build & distribution

- macOS 14.6+, Swift 6, native Swift/AppKit (no Electron).
- `scripts/setup.sh`: launch-agent install (auto-start, keep-alive), `--uninstall`, and `--package` (release `.app` zip).
- Homebrew cask formula in `Cask/` for a future tagged release; notarization still pending.

## See also

- [README.md](README.md) — features, install, configuration, CI
- [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md) — roadmap status
- `docs/ci-pipeline.mmd` — CI flow diagram
