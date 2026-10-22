# Bantay-TUI: Architecture

Bantay-TUI is a native macOS application for managing AI coding agents. It anchors a control plane to the MacBook notch. The application provides agent telemetry, inline approvals, window tiling, and process automation. It supports Herdr, tmux, Zellij, terminal shells, and desktop GUI IDEs.

## System Overview

```
                      +-----------------------------+
                      |       MacBook Notch         |
                      | (Notch Island / Status Pill)|
                      +--------------+--------------+
                                     |
             +-----------------------+-----------------------+
             |                                               |
+------------v------------+                     +------------v------------+
|    Expanded HUD View    |                     |  Infinite Strip Engine  |
| - State-grouped Roster  |                     | - Canvas Window Tiling  |
| - Inline Approvals      |                     | - Spring Physics        |
| - Live Peek Drawer      |                     | - Overview Zoom Mode    |
| - File Shelf & Notes    |                     | - Agent Auto-Chaining   |
| - Reminders & Tasks     |                     | - Status Edge Halos     |
+------------+------------+                     +------------+------------+
             |                                               |
+------------v-----------------------------------------------v------------+
|                         AgentEventManager                               |
| - State Aggregation        - Approval Heartbeat                         |
| - Quota Tracking           - Multi-Agent Timeline                       |
+------------+-----------------------+-----------------------+------------+
             |                       |                       |
+------------v------------+ +--------v------------+ +--------v------------+
|    Herdr Push Stream    | |   Standalone Scan   | |  Control Gateway    |
| - Socket Subscription   | | - Process Sampler   | | - UDS Socket Server |
| - Instant Transitions   | | - Transcript Tailing| | - CLI Subcommands   |
| - Safety Net Polling    | | - SQLite Inspection | | - External Plugins  |
+-------------------------+ +---------------------+ +---------------------+
```

## Architectural Components

### 1. Control Plane & User Interface
- `DynamicIslandApp.swift`: Main application entry point running as an accessory application (`LSUIElement`). Manages the top-level `NSPanel`, menu bar tray item, global hotkey registration (`⌥Space`), and screen configuration observers.
- `NotchStatusView.swift`: Root view for the expanded notch control plane. Hosts the counts header bar, roster scroll view, inline approval controls, and tabbed utilities (Shelf, Tasks, Notes, Media).
- `NotchRosterView.swift` and `AgentRowView.swift`: Render active and completed agent processes. Show status badges, elapsed timers, activity lines, and inline action buttons (Focus, Stop, Peek, Browser View).
- `PeekPanel.swift`: Lightweight floating drawer anchored beside the notch. Displays live streaming terminal output, git diff statistics, and quick action controls (`^C Abort`, `Approve`, `Deny`).
- `RichSessionViewer.swift`: Generates offline, interactive turn-card session views and launches them in default browsers (Chrome, Dia, Safari).
- `SettingsView.swift`: Configuration view covering idle styles, dock sides, quota budgets, push notifications, and keybindings.

### 2. Infinite Strip Window Manager
- `StripLayoutEngine.swift`: Pure layout calculation engine. Computes column coordinates, viewport scroll targets, width presets, overview zoom scaling, and agent auto-chaining pipelines.
- `StripWindowManager.swift`: Manages native window frames and coordinates with macOS Accessibility APIs (`AXUIElement`). Handles column focusing, window reordering, and layout updates.
- `StripGestureInterceptor.swift`: Intercepts two-finger trackpad gestures for smooth horizontal strip scrolling with direction locking.
- `StripOverlayRenderer.swift`: Renders floating ambient status halos around windows corresponding to agent state (amber for pending approval, green for active work).
- `StripViewportAnimator.swift`: Numerical solver for damped harmonic springs with asymptotic resistance outside canvas bounds.

### 3. Agent Telemetry & Event Ingestion
- `AgentEventManager.swift`: Core coordination actor. Merges push events and periodic scans into a unified agent roster, calculates active run-rates, and tracks pending approvals.
- `HerdrEventStream.swift`: Persistent UNIX domain socket connection subscribing to `events.subscribe`. Receives real-time notifications for pane updates and agent detections.
- `AgentDetector.swift`: Discovers standalone agents outside multiplexers by inspecting process names, command arguments, and session transcript files.
- `UniversalQuotaAdapters.swift`: Quota adapters for Codex, Cursor, Claude Code rate limits, and OpenRouter BYOK allocations.
- `UsageTracker.swift`: Calculates token consumption, daily expenditures, prompt cache savings (applying 90% discount on cache reads), and projected run-rates.
- `EventIngestServer.swift`: Localhost HTTP socket listener accepting event payloads from remote environments over SSH tunnels.

### 4. Input & Keystroke Automation
- `StandaloneAgentDispatcher.swift`: Synthesizes keystrokes into target applications. For desktop GUI IDEs, it focuses the chat input with `⌘L`, pastes text with `⌘V`, and presses Return. For terminal agents, it writes directly into the shell.
- `TerminalFocusser.swift`: Resolves the target process and activates its hosting application using macOS Accessibility and AppleScript. Prioritizes running terminals and IDEs via an ordered registry.
- `PlexerAdapter.swift`: Common interface for multiplexers. Automatically resolves active adapters to `TmuxAdapter`, `ZellijAdapter`, or `HerdrSocketAdapter`.

### 5. Control Gateway & External Tools
- `ControlGateway.swift`: UNIX domain socket server listening at `~/Library/Application Support/Bantay-TUI/control.sock`. Processes incoming NDJSON commands from the `bantay` CLI tool.
- `BantayMCPServer.swift`: Implements Model Context Protocol server endpoints, allowing LLMs and external tools to query Bantay status and control agents programmatically.

## Event Processing Pipeline

Incoming telemetry flows through three sources into `AgentEventManager`:

1. **Herdr Push Stream**: Persistent socket connection. Delivers real-time events for pane updates and agent detection (`pane.updated`, `pane.agent_detected`, `pane.closed`).
2. **Standalone Process Scanner**: Background task (`Task.detached`) running every 30 seconds. Scans running processes via `/bin/ps` and reads active transcripts on disk.
3. **Event Ingest Socket**: Local socket listener. Receives structured events forwarded from shell hooks, Claude Code plugins, or SSH tunnels.

The manager consolidates these events, removes duplicate processes by workspace path and PID, and applies the approval heartbeat.

## Approval Execution Model

Approval prompts support three variance types:

- **Yes or No Prompts**: Sends positive or negative confirmation (`y` or `n` followed by Return).
- **Numbered Choices**: Sends the selected index (`1` through `9` followed by Return).
- **Multi-Select Prompts**: Sends selected indices as a comma-separated list (`1,3` followed by Return).

The approval heartbeat checks pending prompts against live processes on every cycle. If an agent advances or terminates independently, stale prompts clear automatically.

## Reliability Subsystems

| Subsystem | Implementation Strategy |
|---|---|
| Full-Screen & Spaces | Observes workspace changes and full-screen events. Delays re-anchoring by 350ms to ensure correct window placement across Spaces. |
| Menu Bar Clearance | Measures auxiliary menu bar areas reported by macOS. Clamps idle status chips to available clear space. |
| Clamshell & Display Wake | Listens for display configuration changes. Re-anchors windows if coordinates fall outside visible screen bounds. |
| Process Safety | Runs heavy I/O, SQLite inspection, and transcript parsing in detached background tasks off the main thread. |
