# Changelog

All notable changes to this project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Infinite Strip Window Manager** (`StripLayoutEngine.swift`, `StripWindowManager.swift`, `StripGestureInterceptor.swift`): Continuous horizontal window tiling engine. Uses damped harmonic springs, overscroll resistance, five width presets, and trackpad gestures.
- **Bird's-Eye Zoom Overview Mode**: Toggles miniature previews of all columns to fit the entire strip on-screen without scrolling (`bantay strip overview`).
- **Canvas Column Reordering & Auto-Chaining**: Added column reordering (`bantay strip reorder`) and agent auto-chaining (`bantay strip autochain`). Auto-chain scans every open window and classifies IDE, browser, terminal, and other apps. It honors `--slug` and normalizes widths to a 50/30/20 layout that fits the viewport. Added a `Chain` HUD action and the `⌃⌥M` hotkey.
- **Window Status Halos** (`StripOverlayRenderer.swift`): Added ambient window borders reflecting agent states: amber for pending approval and green for active execution.
- **Full-Screen Strip Suspension** (`FullScreenMonitor.swift`, `StripWindowManager.swift`, `StripOverlayRenderer.swift`): The strip hides all overlays and tiling in full screen. This includes halos, chevrons, and HUD controls. It uses the Accessibility `AXFullScreen` attribute and a window-bounds fallback. Layout restores automatically after exit.
- **Window and Column Navigation** (`StripGestureInterceptor.swift`, `StripLayoutEngine.swift`, `NotchStatusView.swift`): `⌃⌥↑` and `⌃⌥↓` cycle windows in the active column. `⌃⌥Home` and `⌃⌥End` jump to the first or last column. Clicking the active radar card cycles stacked windows. Column focus now tracks the exact focused `CGWindowID`.
- **Standalone Desktop GUI IDE Automation** (`StandaloneAgentDispatcher.swift`): Keystroke automation for Antigravity IDE, Cursor, Windsurf, Zed, and VS Code. Presses `⌘L` to focus chat and pastes input.
- **Interactive Peek Drawer Quick Actions** (`PeekPanel.swift`): Added docked action controls (`^C Abort`, `Approve`, `Deny`, choices, status badge) to the log drawer.
- **Rich Session Browser Viewer** (`RichSessionViewer.swift`): Generates an offline HTML transcript viewer with structured turn cards. Opens directly in the default browser.
- **Control Gateway** (`ControlGateway.swift`): Added a UNIX domain socket server (`control.sock`). Processes NDJSON commands for strip management, settings, and agent status queries.
- **Model Context Protocol Server** (`BantayMCPServer.swift`): Added an MCP server endpoint. Exposes Bantay state and agent controls to AI clients.
- **Multi-Vendor Quota Tracking** (`UniversalQuotaAdapters.swift`): Added quota adapters for Claude Code, Codex, Cursor, OpenRouter, and Ollama.
- **Prompt Caching Economics & Savings** (`UsageTracker.swift`): Applies a 90% discount on cache read tokens and calculates cumulative cost savings.
- **Live Countdowns & Quota Failover** (`TaskDispatcher.swift`): Shows reset countdowns (`Resets in 1h 24m`) and routes tasks to backup providers during quota saturation.
- **Sanitized Semantic Activity Detection** (`AgentDetector.swift`, `IslandMetrics.swift`): Extracts clean status messages by stripping ANSI escape sequences and braille spinners.
- **Apple Reminders Sync & Natural Language Entry** (`RemindersProvider.swift`, `NaturalLanguageParser.swift`): Added EventKit synchronization and natural language task parsing.
- **Push Alerts & Status Bar** (`AgentAlertNotifier.swift`, `TmuxStatusInstaller.swift`): Added ntfy.sh push notifications and an optional tmux status-right bar summary.

### Changed

- **Terminal Focus Registry** (`TerminalFocusser.swift`): Corrected the Ghostty bundle identifier to `com.mitchellh.ghostty` and added `com.google.antigravity-ide`. Added PID ancestor lookup for CLI agents.
- **Setup Script Deployment** (`scripts/setup.sh`): Updated binary installation to check modification timestamps (`-nt`). Installs the newest build to the app bundle.
- **Peek Panel Event Monitoring** (`PeekPanel.swift`): Deferred click-outside dismissal to the next runloop turn. Ignores clicks on the Notch HUD window to prevent premature dismissal.
- **HUD Row Controls** (`AgentRowView.swift`, `NotchStatusView.swift`): Canonicalized agent names by stripping project path slugs before routing focus and prompt dispatching.
- **Live Strip Status** (`ControlGateway.swift`, `StripStatusProvider.swift`): `bantay strip status` now returns live columns, window titles, agent metadata, Accessibility state, and full-screen state. It replaces the static config output.

### Fixed

- Fixed Ghostty terminal focus failing due to invalid bundle identifier.
- Fixed Peek drawer closing immediately when clicked from the notch.
- Fixed GUI IDE prompts pasting into active code editors instead of chat.
- Fixed setup script copying stale binaries when fresh builds were available.
- Fixed approval controls being disabled for standalone agents.
- Fixed the notch expanding over an approval popup on hover. Popup buttons stay clickable.
- Fixed auto-chain ignoring the project slug and only chaining windows that were already in the strip.
- Fixed auto-chain dumping non-terminal apps into the Tests column and producing a 110% wide layout.
- Fixed strip focus activating the wrong app by parsing a CGWindowID as a PID.
- Fixed standalone approvals from the notch, Peek drawer, and menu bar bypassing the standalone dispatcher.
- Fixed `waiting` prompts missing approval controls in the closed pill.
- Fixed the Settings window opening under the notch island.
- Fixed the Peek drawer docking to the full host window instead of the visible island.
- Fixed the approval popup rendering inside the notch cutout. It now sits below the notch with room for the full request.
- Fixed approval popups showing only a generic label. They now show the command, path, tool, question, and a live pane excerpt when needed.
- Fixed repeated approval popups after an answer. Duplicate blocked events stay suppressed until the agent reports a new status.
- Replaced AppleScript and System Events keystrokes with Core Graphics keyboard events. Approval actions no longer trigger macOS Automation prompts.
- Fixed repeated macOS Accessibility prompts after rebuilds. Local installs now use a stable self-signed signing identity, so the grant survives code changes.
- Limited the Accessibility prompt to once per app process. A stale grant no longer triggers a prompt loop.
- Fixed strip halos, chevrons, and HUD controls remaining visible over full-screen apps.
- Fixed a stale strip timer resizing a full-screen window.
- Fixed strip navigation targeting the frontmost process instead of the focused window.

## [0.1.0] - 2026-08-05

- Initial baseline release. Included notch island idle strip, expanded control plane, approval queue, universal agent detection, and Go TUI client.
