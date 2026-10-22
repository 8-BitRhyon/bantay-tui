# Changelog

All notable changes to this project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Infinite Strip Window Manager** (`StripLayoutEngine.swift`, `StripWindowManager.swift`, `StripGestureInterceptor.swift`): Continuous horizontal window tiling engine. Uses damped harmonic springs, overscroll resistance, five width presets, and trackpad gestures.
- **Bird's-Eye Zoom Overview Mode**: Toggles miniature previews of all columns to fit the entire strip on-screen without scrolling (`bantay strip overview`).
- **Canvas Column Reordering & Auto-Chaining**: Added column reordering (`bantay strip reorder`) and agent auto-chaining (`bantay strip autochain`). Arranges windows into IDE (50%), Browser (35%), and Tests (25%).
- **Window Status Halos** (`StripOverlayRenderer.swift`): Added ambient window borders reflecting agent states: amber for pending approval and green for active execution.
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

### Fixed

- Fixed Ghostty terminal focus failing due to invalid bundle identifier.
- Fixed Peek drawer closing immediately when clicked from the notch.
- Fixed GUI IDE prompts pasting into active code editors instead of chat.
- Fixed setup script copying stale binaries when fresh builds were available.
- Fixed approval controls being disabled for standalone agents.

## [0.1.0] - 2026-08-05

- Initial baseline release. Included notch island idle strip, expanded control plane, approval queue, universal agent detection, and Go TUI client.
