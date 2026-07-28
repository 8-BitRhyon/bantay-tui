# Bantay-TUI -- Agent Sentinel Notch HUD

Native SwiftUI macOS app that turns the MacBook notch into an interactive agent-state display, reading lifecycle events directly from Herdr.

## Why
Focus-notify (installed) sends native macOS toasts on `agent_status_changed`. This complements it with persistent notch-level visibility: which agent is `blocked`, which just finished (`done`), which needs approval (`accessRequest`), without opening Notification Center.

## Architecture

| Component | Role | Source Basis |
|---|---|---|
| `DynamicIslandApp.swift` | Main SwiftUI entry | Notchly `App/DynamicIslandApp.swift` |
| `AgentEventManager.swift` | Reads events file / socket | Notchly `Managers/AgentEventManager.swift` |
| `HerdrSocketAdapter.swift` | Swift wrapper for herdr local socket (`pane list`, `wait agent-status`) | Custom (herdr socket docs) |
| `AgentEventKind.swift` | Enum mapping herdr states | Notchly `AgentEventKind` |
| `NotchStatusView.swift` | Dynamic Island rendering | Notchly `Views/Island/` |
| `NotchHUDConfig.swift` | Settings: sound per event, auto-clear TTL, sticky approvals | Notchly `Managers/SettingsManager.swift` |

## Events File vs Socket

Notchly (original) reads `~/Library/Application Support/Notchly/agent-events.jsonl` (Codex hooks write to it). Bantay-TUI has two options:

1. **File adapter** (fast): herdr plugin (`focus-notify` or new adapter) writes `agent-events.jsonl` to `~/Library/Application Support/Bantay-TUI/agent-events.jsonl`. Bantay-TUI reads same file.
2. **Socket adapter** (direct): Swift connects to herdr local unix socket, polls `pane agent-status` and `pane list`. No intermediate file.

Recommendation: start with file adapter (reuse Notchly's `AgentEventManager.readPendingEvents()` logic), then add socket adapter for lower latency.

## Herdr Integration Points

| Herdr Plugin / Feature | Event Type | Bantay-TUI Mapping |
|---|---|---|
| `freebuff.integration` | `blocked`, `working`, `idle` | `AgentEventKind.waiting`, `.started`/`.progress`, `.completed`/`.clear` |
| `commandcode.integration` | `blocked`, `working`, `idle`, `done` | Same mapping; `cmd-hooks` writes events |
| `focus-notify` (`pane.agent_status_changed`) | `blocked`, `done`, `idle`, `unknown` | Direct event source; Bantay-TUI subscribes |
| `worktrunk` (workspace isolation) | Worktree creation | Optional workspace label in notch |
| `resurrect` (session persistence) | Restored layout | Optional session-ID tag |

## Click-to-Focus

Notch click triggers herdr CLI: `herdr pane focus <pane_id>` (same mechanism as `focus-notify`). Pane ID resolved via event metadata (`pane.id` in event file, or `pane list` lookup in socket adapter).

## Build Requirements

- macOS 14.6+ (same as Notchly)
- SwiftUI, AppKit
- No Electron; native Swift binary
- Open source (MIT license, same as Notchly)
- Notarized release via `notarytool` (optional for public download; can distribute as `.dmg` or `.zip` for manual install)

## Installation Path

Manual (for now): download `.dmg` from GitHub releases. Future: Homebrew cask (`brew install --cask bantay-tui`) once notarized.
