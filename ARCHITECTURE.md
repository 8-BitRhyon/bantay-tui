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
- `NotchStatusView.swift`: Root view for the expanded notch control plane. Hosts the counts header bar, roster scroll view, and core tabs (Inbox, Tasks, History) with utility pills (Shelf, Notes, Media).
- `ApprovalCardView.swift`: Unified approval card for blocked agents. Shows the exact request, risk badge, queue position, and actions. Waiting states show Review and Open instead of blind Approve and Deny.
- `ApprovalPromptResolver.swift`: Pure parser for live pane prompts. Extracts the exact command, path, question, numbered choices, multi-select choices, and risk tier from terminal text.
- `AgentPresentation.swift`: Pure presentation logic. Humanizes raw tool text, classifies risk, and groups subagents under their project workspace.
- `NotchRosterView.swift` and `AgentRowView.swift`: Render the inbox. Approval cards lead, working groups fold subagents, and finished agents use compact rows. Clicking a row focuses its window.
- `DesktopHUDController.swift` and `DesktopHUDView.swift`: Bottom-center window-only HUD. Shows column cards, Chain, Overview, navigation, and a Layout menu. Auto-hides unless pinned and never appears in full screen.
- `QuotaMonitor.swift`: Cached background quota polling. Keeps subprocess and disk reads out of view rendering.
- `SettingsRoute.swift`: Deep-link destinations for the single shared Settings modal.
- `PeekPanel.swift`: Lightweight floating drawer anchored beside the notch. Displays live streaming terminal output, git diff statistics, and quick action controls (`^C Abort`, `Approve`, `Deny`).
- `RichSessionViewer.swift`: Generates offline, interactive turn-card session views and launches them in default browsers (Chrome, Dia, Safari).
- `SettingsView.swift`: Configuration view covering idle styles, dock sides, quota budgets, push notifications, and keybindings.

### 2. Infinite Strip Window Manager
- `StripLayoutEngine.swift`: Pure layout calculation engine. Computes column coordinates, viewport scroll targets, width presets, overview zoom scaling, and agent auto-chaining pipelines. Auto-chain classifies IDE, browser, terminal, and other windows. It prefers project-slug matches per stage and normalizes widths to 1.0.
- `StripWindowManager.swift`: Manages native window frames with macOS Accessibility APIs (`AXUIElement`). Scans live windows for auto-chain. Tracks the focused `CGWindowID` for focus and navigation. Skips window tiling when a full-screen app is active.
- `StripStatusProvider.swift`: Sendable snapshot bridge between the AppKit strip manager and the control gateway. Keeps the pure logic harness free of UI-only imports.
- `FullScreenMonitor.swift`: Polls the frontmost app and publishes `isFullScreen`. Uses the Accessibility `AXFullScreen` attribute first. Falls back to window bounds for apps that do not expose the attribute.
- `StripGestureInterceptor.swift`: Intercepts global strip hotkeys and two-finger trackpad gestures. Column and window navigation use `⌃⌥` chords. Scroll gestures stay disabled in full screen.
- `StripOverlayRenderer.swift`: Renders floating status halos around windows. Amber is reserved for approvals. Cyan marks working and focused windows. Only approvals pulse. Halo and chevron panels hide independently. All overlay panels hide in full screen.
- `StripViewportAnimator.swift`: Numerical solver for damped harmonic springs with asymptotic resistance outside canvas bounds.

#### Full-Screen Suppression

`FullScreenMonitor` reports the full-screen state of the frontmost app. When the state is true, the strip manager takes these actions:

1. Hide status halos, navigation chevrons, and the Desktop HUD.
2. Stop the viewport animator.
3. Skip `syncWindows` and frame application.
4. Resume layout when the state becomes false.

A per-window `AXFullScreen` check also guards `applyComputedFrames`. This check prevents a stale timer tick from resizing a full-screen window. The island uses the same monitor. Its `showInFullScreen` setting stays independent from the strip.

### 3. Agent Telemetry & Event Ingestion
- `AgentEventManager.swift`: Core coordination actor. Merges push events and periodic scans into a unified agent roster, calculates active run-rates, and tracks pending approvals.
- `HerdrEventStream.swift`: Persistent UNIX domain socket connection subscribing to `events.subscribe`. Receives real-time notifications for pane updates and agent detections.
- `AgentDetector.swift`: Discovers standalone agents outside multiplexers by inspecting process names, command arguments, and session transcript files.
- `UniversalQuotaAdapters.swift`: Quota adapters for Codex, Cursor, Claude Code rate limits, and OpenRouter BYOK allocations.
- `UsageTracker.swift`: Calculates token consumption, daily expenditures, prompt cache savings (applying 90% discount on cache reads), and projected run-rates.
- `EventIngestServer.swift`: Localhost HTTP socket listener accepting event payloads from remote environments over SSH tunnels.

### 4. Input & Keystroke Automation
- `StandaloneAgentDispatcher.swift`: Synthesizes keystrokes into target applications. For desktop GUI IDEs, it focuses the chat input with `⌘L`, pastes text with `⌘V`, and presses Return. For terminal agents, it writes directly into the shell.
- `TerminalFocusser.swift`: Resolves the target process and activates its hosting application with `NSWorkspace`. Prioritizes running terminals and IDEs via an ordered registry.
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
- **Multi-Select Prompts**: Sends selected indices as one space-separated line (`1 3` followed by Return).

Every approval surface routes through `AgentEventManager`: the notch popup, inbox approval cards, Peek drawer, Notification Center actions, and menu-bar actions. The manager writes OpenCode decisions and sends multiplexer actions. It sends standalone keystrokes through `StandaloneAgentDispatcher`.

Status-only `blocked` events often carry no request text. `AgentEventManager` captures the live pane or transcript and `ApprovalPromptResolver` extracts the exact command, path, question, and choices. Until that detail arrives, the surface shows Review only. A prompt without concrete detail or choices never offers blind Approve and Deny. The same fingerprint stays suppressed after an answer until the agent reports a non-approval status, so repeated `blocked` heartbeats cannot ask the same question again.

Standalone agents have no multiplexer pane id. `IslandMetrics.actionablePaneId` derives a synthetic `standalone:<source>` id. This id keeps the popup, Notification Center, and menu bar in agreement and resolves the agent cwd for dispatch.

The closed notch shows an approval popup with Approve and Deny controls, numbered choice controls, or multi-select controls. Hover expansion is suppressed while this popup is visible. The popup keeps its buttons under the pointer.

The popup starts below the physical notch. It shows the exact command, file path, tool, or question instead of a generic label. When a multiplexer event has no title, the popup reads a live pane excerpt. Approval detail text skips the HUD cleaner because that cleaner shortens absolute paths.

Approval input synthesis uses Core Graphics keyboard events. This reuses the Accessibility grant that Bantay already holds and avoids AppleScript or System Events, which trigger a separate macOS Automation prompt.

macOS TCC ties Accessibility grants to a code requirement. Ad-hoc signatures use the per-build cdhash, so every rebuild looks like a new app. Local installs therefore use a stable self-signed `Bantay Local Dev` certificate, created by `scripts/ensure-dev-signing-identity.sh` on first setup. The resulting requirement is anchored to the certificate, so the Accessibility grant survives later rebuilds. Distribution builds still use Developer ID signing and notarization.

The Accessibility prompt is shown at most once per app process. A stale grant cannot create a prompt loop when the strip starts or toggles.

After an approval action, the manager clears any pending state for that pane and removes the visible prompt. Duplicate `blocked` or `waiting` events for the same pane stay suppressed for 12 seconds, or until the agent reports a different status. This prevents a repeated popup for a request the user just answered.

The approval heartbeat checks pending prompts against live processes on every cycle. If an agent advances or terminates independently, stale prompts clear automatically.

## Reliability Subsystems

| Subsystem | Implementation Strategy |
|---|---|
| Full-Screen & Spaces | Observes workspace changes and full-screen state. Delays re-anchoring by 350ms for correct placement. Hides strip overlays and tiling in full screen. |
| Menu Bar Clearance | Measures auxiliary menu bar areas reported by macOS. Clamps idle status chips to available clear space. |
| Clamshell & Display Wake | Listens for display configuration changes. Re-anchors windows if coordinates fall outside visible screen bounds. |
| Process Safety | Runs heavy I/O, SQLite inspection, and transcript parsing in detached background tasks off the main thread. |
