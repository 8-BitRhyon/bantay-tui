# Bantay-TUI: Agentic Control Plane in Your Notch

[![CI](https://github.com/8-BitRhyon/bantay-tui/actions/workflows/ci.yml/badge.svg)](https://github.com/8-BitRhyon/bantay-tui/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Bantay-TUI is a native macOS application for managing AI coding agents. It places an interactive control plane directly in the MacBook notch. You can monitor progress, review code diffs, approve actions, and tile windows without leaving your current task.

Bantay supports agents running in Herdr, tmux, Zellij, standard terminals, and desktop IDEs. It shows live status when an agent is working, blocked, or complete. You can approve requests with one click or key press.

## Features

### 1. The Notch Island (HUD)
- **Idle Status Strip**: Shows agent chips next to the notch with color status dots. The strip clamps to screen bounds to prevent menu bar overlap.
- **Expanded Control Plane**: Press `⌥Space` or hover over the notch to open the main control panel:
  - **Inline Approvals**: Answer yes/no prompts, numbered choices, or multi-select lists directly in the roster row.
  - **State-Grouped Roster**: Organizes agents by state: `Blocked`, `Working`, `Completed`, `Failed`, and `Idle`.
  - **Peek Drawer**: Click the eye icon to view live output, git diff summaries, and quick controls (`^C Abort`, `Approve`, `Deny`).
  - **Session Viewer**: Click the compass icon to open a structured session report in your web browser.
  - **File Shelf**: Drag files over the notch to save them to a persistent shelf with QuickLook previews.
  - **Task Manager**: Add tasks with natural language input. Tasks synchronize with Apple Reminders.

### 2. Infinite Strip Window Manager
Bantay includes a horizontal window tiling engine for macOS:
- **Smooth Physics**: Windows scroll along a horizontal canvas using damped spring physics.
- **Width Presets**: Set column width to 35%, 50%, 61.8%, 66.7%, or 100%.
- **Overview Mode**: Scale all columns to fit the screen without scrolling (`bantay strip overview`).
- **Column Reordering**: Move columns using gestures or the CLI (`bantay strip reorder --from <idx> --to <idx>`).
- **Auto-Chaining**: Organizes windows into a 3-part layout: IDE (50%) -> Browser (35%) -> Tests (25%).
- **Status Halos**: Displays ambient colored borders on windows to show live agent status.

### 3. Agent and Quota Telemetry
- **Desktop IDE Support**: Sends commands to Google Antigravity IDE, Cursor, Windsurf, Zed, and VS Code. It also supports terminal agents such as Claude Code, OpenCode, Codex, and Gemini.
- **Live Quota Tracking**: Reads local SQLite databases for Codex and Cursor. Ingests Claude Code rate limits, OpenRouter keys, and Ollama models.
- **Quota Safeguards**: Displays countdowns until reset times. Routes work to backup models when limits are reached.

## Quick Actions and Shortcuts

| Action | Method |
|---|---|
| Open or close Notch Island | Press `⌥Space` |
| Approve or deny in HUD | Press `Y` or `N` |
| Select numbered choice | Press `1` through `9` |
| Open Peek drawer | Click the eye icon |
| Open session in browser | Click the compass icon |
| Focus agent application | Click the arrow icon |
| Stop or abort agent (`^C`) | Click the stop icon |
| Write prompt to agent | Click the agent row |
| Add file to shelf | Drag file over the notch |
| Toggle Infinite Strip | Run `bantay strip toggle` |
| Toggle Overview Mode | Run `bantay strip overview` |
| Jump to pending approval | Run `bantay strip approval` |

## CLI Reference

Bantay provides a control socket at `~/Library/Application Support/Bantay-TUI/control.sock`. You can control Bantay with the command line:

```bash
# Manage the Infinite Strip
bantay strip toggle                           # Show or hide the window strip
bantay strip overview                         # Toggle overview zoom mode
bantay strip focus --dir [left|right]          # Move focus to the next column
bantay strip center                           # Center the active column
bantay strip width [--mode cycle|expand|shrink] # Change the column width preset
bantay strip approval                         # Focus the window waiting for approval
bantay strip reorder --from 0 --to 1          # Move column 0 to position 1
bantay strip autochain --slug <project>       # Tile windows for the project
bantay strip status                           # Output layout state as JSON

# System Commands
bantay settings                               # Open the Settings window
bantay ping                                   # Check daemon status
```

## Installation

### Method 1: Background Service (Recommended)

1. Build the release binary:
   ```bash
   swift build -c release
   ```

2. Run the setup script:
   ```bash
   bash scripts/setup.sh
   ```

The script installs the application bundle to `~/Library/Application Support/Bantay-TUI/Bantay-TUI.app`. It creates a background launch agent that starts automatically.

To restart the background service:
```bash
launchctl kickstart -k gui/$(id -u)/com.bantay-tui.agent
```

To uninstall Bantay:
```bash
bash scripts/setup.sh --uninstall
```

### Method 2: Homebrew Cask

Install via Homebrew:
```bash
brew tap 8-BitRhyon/bantay-tui
brew install --cask bantay-tui
```

### System Requirements

- macOS 13.0 or later
- Swift 6.0 toolchain (Xcode 16 or later to run tests)
- Optional tools: Herdr, tmux, Zellij, Node.js 18+

## Architecture and Reliability

Bantay uses native Swift and AppKit. It does not use Electron:

1. **Heartbeat Verification**: Verifies approval prompts against active processes on every cycle. Stale prompts clear automatically.
2. **Display Transitions**: Repositions windows correctly when you change Spaces, switch full-screen apps, or attach monitors.
3. **Menu Bar Detection**: Measures auxiliary menu areas to prevent overlap with menu bar icons.
4. **Application Focus Registry**: Activates target applications using a priority registry. The registry includes Ghostty, Antigravity IDE, standard terminals, and desktop IDEs.
5. **Asynchronous Execution**: Runs process scans and file queries in background tasks off the main thread.

For technical diagrams and internal protocol details, refer to [ARCHITECTURE.md](ARCHITECTURE.md).

## Configuration

Settings are stored in `UserDefaults` under domain `BantayTUI`. Open the Settings window with `Cmd-,` or run `bantay settings`:

| Key | Default | Description |
|---|---|---|
| `islandDockSide` | `center` | Placement of the idle strip (`left`, `right`, or `center`) |
| `idleStyle` | `names` | Style of idle chips (`names`, `dots`, or `summary`) |
| `idleMaxChips` | `3` | Maximum visible chips before the `+N` badge (1 to 6) |
| `expandedGroupByState` | `true` | Group agents by status in the roster |
| `globalHotkeyEnabled` | `true` | Enable the global `⌥Space` shortcut |
| `keyboardShortcuts` | `true` | Enable `Y`, `N`, and number keys in the HUD |
| `edgeGlowEnabled` | `true` | Show amber edge glow when an approval is waiting |
| `showShelfTab` / `shelfLimit` | `true` / `20` | Enable the Shelf tab and set item limit |
| `showTasksTab` | `true` | Enable the Tasks tab |
| `dailyBudgetUSD` | `10.0` | Daily spend budget in USD |
| `ntfyTopic` / `ntfyServer` | `""` / `https://ntfy.sh` | Topic and server for ntfy push alerts |
| `tmuxStatusEnabled` | `false` | Enable status integration in tmux |
| `preferredTerminalBundleID` | nil | Bundle identifier of preferred terminal |

## CI/CD Pipeline

The project runs seven automated test stages on every change:

| Layer | Command | Description |
|---|---|---|
| 1. Format | `swift format lint --recursive --strict Sources Tests` | Verifies code style compliance |
| 2. Compile | `swift build` | Compiles debug build without warnings |
| 3. Unit Tests | `swift test` | Runs the test suite |
| 3.5. Logic Harness | `bash scripts/build-logic-harness.sh` | Tests all 153 logic layers (L1 through L153) |
| 4. Release Build | `swift build -c release` | Compiles optimized release binary |
| 4.5. Smoke Test | Launch verification | Verifies the app runs for 10 seconds without crashing |
| 5. Security | Gitleaks and SHA checks | Scans for secrets and checks pinned action versions |
| 6. Go TUI | `go test ./...` | Verifies the terminal client |

## Development Commands

Format source files:
```bash
swift format format --in-place --recursive Sources Tests
```

Compile the project:
```bash
swift build
```

Run unit tests:
```bash
swift test
```

Run the 153-layer logic harness:
```bash
bash scripts/build-logic-harness.sh
```

## License

Released under the MIT License. Refer to [LICENSE](LICENSE) for details.
