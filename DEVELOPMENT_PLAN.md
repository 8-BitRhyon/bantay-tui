# Bantay-TUI Development Plan

Roadmap and current state for the Bantay-TUI macOS agentic control plane and workspace manager. Tracks against the architecture defined in [ARCHITECTURE.md](ARCHITECTURE.md).

## Current State

| Area | Status |
|---|---|
| Island HUD | Compact idle strip and expanded control panel. Includes state-grouped roster, inline approvals, and tabbed utilities. |
| Infinite Strip | Horizontal window manager with spring physics, width presets (35% to 100%), overview zoom mode, and status halos. |
| Approvals | Execution of yes/no prompts, numbered choices, and multi-select lists directly from HUD rows. Backed by the approval heartbeat. |
| Agent Dispatch | Keystroke automation for GUI IDEs (using `⌘L` chat focusing) and direct terminal shell pasting. |
| Telemetry Pipeline | Herdr socket stream for instant state updates, standalone CLI process scanner, and SSH tunnel ingest. |
| Quota & BYOK | SQLite inspection for Codex and Cursor, Claude Code rate limits, OpenRouter keys, and Ollama failover. |
| Notifications | Push alerts via ntfy.sh, tmux `status-right` summary, and macOS Notification Center alerts when the HUD is hidden. |
| Reliability Core | Space and full-screen transition re-anchoring, display hot-swap re-centering, auxiliary menu bar clearance clamping, and ordered terminal registry. |
| Logic Harness | 153-layer pure-logic verification suite (`.kilo/LogicCheck.swift` running without XCTest) plus CI XCTest suite. |
| CI / Automation | 7-layer validation pipeline in GitHub Actions (Format, Compile, Tests, Logic Checks L1 to L153, Release build, Launch smoke, and Go TUI verification). |

## Vision

The MacBook notch serves as the primary glanceable surface for AI coding workflows. Users can monitor progress, review code diffs, answer permissions, and organize windows without switching context.

## Completed Milestones

- **Notch Island HUD**: Compact idle status pill, expanded control plane, state-grouped roster, and inline approval execution.
- **Infinite Strip Window Manager**: Continuous horizontal canvas window tiling with damped spring physics, zoom overview, drag reordering, and project auto-chaining.
- **Universal Agent Support**: Keystroke automation for desktop GUI IDEs (Antigravity IDE, Cursor, Windsurf, Zed, VS Code) and terminal agents.
- **Interactive Peek Drawer**: Docked quick controls (`^C Abort`, `Approve`, `Deny`, live indicator) alongside live log output and git diff stats.
- **Rich Session Viewer**: Offline browser-based transcript viewer with turn-by-turn cards.
- **Multiplexer Integration**: Fully wired adapter provider resolving to Herdr, Tmux, or Zellij.
- **Barrie Task Management**: Natural language task parsing with Apple Reminders EventKit synchronization.
- **Speed & Usability**: Global `⌥Space` hotkey, keyboard shortcuts (`Y`, `N`, `1` to `9`), edge-glow alerts, and persistent file shelf.

## Remaining Roadmap

### M1. Distribution & Packaging
1. **Tagged Release**: Build official release artifacts, calculate Homebrew Cask SHA256 hashes, and document Gatekeeper bypass.
2. **Auto-Update Support**: Evaluate Sparkle framework integration for automatic background updates.
3. **Homebrew Tap**: Publish the cask formula to the tap repository.

### M2. Remote Bridges & Mobile Companions
1. **Headless Web Dashboard**: Optional lightweight local web dashboard mirroring notch state for secondary monitors or mobile browsers.
2. **Push Bridge Optimization**: Expand ntfy.sh push payload actions to allow direct approval responses from mobile push notifications.

## Technical Risks & Mitigations

- **WindowServer Transitions**: macOS space switches and display reconfigurations can occasionally strand borderless windows. Mitigated by debounced re-anchoring handlers observing display and space notifications.
- **Accessibility API Permissions**: Native window tiling and keystroke synthesis require macOS Accessibility permissions. Mitigated by checking `AXIsProcessTrusted` and providing inline permission guidance.
- **Process Verification**: Background CLIs can exit without triggering socket close events. Mitigated by periodic process sampling and the approval heartbeat.
