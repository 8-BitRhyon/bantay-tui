# Bantay-TUI: Agentic Control Plane in Your Notch

[![CI](https://github.com/8-BitRhyon/bantay-tui/actions/workflows/ci.yml/badge.svg)](https://github.com/8-BitRhyon/bantay-tui/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Bantay-TUI is a native macOS application for managing AI coding agents. It places an interactive control plane directly in the MacBook notch. You can monitor progress, review code diffs, approve actions, and tile windows without leaving your current task.

Bantay supports agents running in Herdr, tmux, Zellij, standard terminals, and desktop IDEs. It shows live status when an agent is working, blocked, or complete. You can approve requests with one click or key press.

## Features

### 1. The Notch Island (HUD)
- **Idle Status Strip**: Shows agent chips next to the notch with color status dots. The strip clamps to screen bounds to prevent menu bar overlap.
- **Expanded Control Plane**: Hover over the notch to open the main control panel:
  - **Approval Cards**: Blocked agents render as cards. Each card shows the exact request, risk badge, queue position, and full choice labels.
  - **Review-Only Waits**: Prompts without a concrete request or choices offer Review and Open, never a blind Approve or Deny.
  - **State-Grouped Roster**: Organizes agents into `Needs you`, `Working`, and `Idle`. Subagents fold under their project with an expander.
  - **Peek Drawer**: Click Review to view live output and git diff summaries. Reply from the row menu or press `R`.
  - **Session Viewer**: Open a structured session report in your web browser from the row menu.
  - **Media Shelf**: Drag files, images, links, or text over the notch to save them to a persistent shelf. Drag a card back into Finder, an upload field, or an editor. A 1 GB budget evicts the oldest items first, and expired or unreferenced files are cleaned up automatically.
  - **Task Manager**: Add tasks with natural language input. Tasks synchronize with Apple Reminders.

### 2. Infinite Strip Window Manager
Bantay includes a horizontal window tiling engine for macOS:
- **Smooth Physics**: Windows scroll along a horizontal canvas using damped spring physics.
- **Width Presets**: Set column width to 35%, 50%, 61.8%, 66.7%, or 100%.
- **Overview Mode**: Scale all columns to fit the screen without scrolling (`bantay strip overview`).
- **Column Reordering**: Move columns using gestures or the CLI (`bantay strip reorder --from <idx> --to <idx>`).
- **Auto-Chaining**: Scans every open window and organizes the IDE, browser, and terminal into a 50/30/20 layout. Widths always sum to 100%. A project slug makes each stage prefer matching windows. Other apps go to a trailing `Other` column instead of being mislabeled as tests.
- **Status Halos**: Displays ambient colored borders on windows to show live agent status.
- **Desktop HUD**: Press `⌃⌥Space` to open a bottom-center window map. It shows column cards, Chain, Overview, navigation, and a Layout menu. It auto-hides and never appears in full screen.
- **Full-Screen Aware**: Strip halos, navigation chevrons, Desktop HUD, and window tiling pause when the frontmost app is in full screen. The strip restores when you leave full screen.
- **Keyboard Navigation**: Use `⌃⌥←` and `⌃⌥→` to move between columns. Use `⌃⌥↑` and `⌃⌥↓` to cycle windows in the active column. Use `⌃⌥Home` and `⌃⌥End` to jump to the first or last column. Click the active radar card to cycle stacked windows.

### 3. Agent and Quota Telemetry
- **Desktop IDE Support**: Sends commands to Google Antigravity IDE, Cursor, Windsurf, Zed, and VS Code. It also supports terminal agents such as Claude Code, OpenCode, Codex, and Gemini.
- **Live Quota Tracking**: Reads local SQLite databases for Codex and Cursor. Ingests Claude Code rate limits, OpenRouter keys, and Ollama models.
- **Quota Safeguards**: Displays countdowns until reset times. Routes work to backup models when limits are reached.

## Quick Actions and Shortcuts

| Action | Method |
|---|---|
| Open or close Notch Island | Hover the notch or use the menu bar |
| Approve or deny in HUD | Press `Y` or `N` |
| Reply to the top agent | Press `R` |
| Select numbered choice | Press `1` through `9` |
| Review live output | Click Review on the approval card or row menu |
| Open session in browser | Use the row More menu |
| Focus agent application | Click the agent row |
| Stop or abort agent (`^C`) | Use the row More menu |
| Toggle Desktop HUD | Press `⌃⌥Space` |
| Add media to shelf | Drag a file, image, link, or text over the notch |
| Use a shelf item | Drag a shelf card into any app or input |
| Toggle Infinite Strip | Run `bantay strip toggle` |
| Move between columns | Press `⌃⌥←` or `⌃⌥→` |
| Cycle windows in the active column | Press `⌃⌥↑` or `⌃⌥↓` |
| Jump to the first or last column | Press `⌃⌥Home` or `⌃⌥End` |
| Chain windows | Press `⌃⌥M` or click `Chain` in the Desktop HUD |
| Toggle Overview Mode | Run `bantay strip overview` |
| Toggle Desktop HUD | Run `bantay strip hud` |
| Open Settings at a section | Run `bantay settings [desktop|approvals|notch]` |
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
bantay strip autochain [--slug <project>]     # Chain all open windows for the project
bantay strip hud                              # Toggle the Desktop HUD
bantay strip status                           # Output live columns, windows, and full-screen state as JSON

# System Commands
bantay settings                               # Open the Settings window
bantay settings [route]                       # Open Settings at a section (desktop, approvals, notch)
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

### Local Development Signing

`scripts/setup.sh` creates a local self-signed certificate named `Bantay Local Dev` on first run and signs the installed app with it. This gives macOS a stable code requirement. Accessibility and Reminders permissions therefore survive rebuilds.

Run `bash scripts/doctor.sh` when a permission prompt keeps returning. It prints the stored code requirement and lists every certificate with the signing name. These two failures cause most repeats:

1. The requirement shows `cdhash`. The build is ad-hoc signed. Ad-hoc signatures change on every rebuild, so macOS sees a new app. Rerun `scripts/setup.sh` and check that it prints `signed-with: Bantay Local Dev`.
2. Two certificates share the same name. `codesign` picks one unpredictably, so the requirement changes between installs. `scripts/doctor.sh` reports duplicates. Keep one identity, or let `scripts/setup.sh` recreate the keychain.

If grants look stale after switching signatures, reset them once and grant again:

```bash
tccutil reset Accessibility com.bantay-tui
tccutil reset Reminders com.bantay-tui
```

Set `BANTAY_ALLOW_ADHOC=1` to accept ad-hoc signing when no identity exists. Without it, `scripts/setup.sh` stops instead of silently switching signatures. Ad-hoc builds get a new cdhash on every rebuild, which resets permissions. Distribution builds continue to use Developer ID signing and notarization.

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
| `idleStyle` | `project` | Closed strip content: lead project + count (`project`), count only (`summary`), agent names (`names`), or dots (`dots`) |
| `idleMaxChips` | `3` | Maximum visible chips before the `+N` badge (1 to 6) |
| `expandedGroupByState` | `true` | Group agents by status in the roster |
| `globalHotkeyEnabled` | `true` | Enable global hotkeys (`⌥Y` approve, `⌥N` deny, `⌥S` snooze, `⌥,` settings) |
| `globalHotkeyApproveEnabled` / `globalHotkeyDenyEnabled` / `globalHotkeySnoozeEnabled` | `true` / `true` / `false` | Toggle each global hotkey separately |
| `keyboardShortcuts` | `true` | Enable `Y`, `N`, and number keys in the HUD |
| `edgeGlowEnabled` | `true` | Show amber edge glow when an approval is waiting |
| `enableSpendGlow` | `true` | Show a cyan, amber, or red spend stroke around the collapsed notch |
| `showShelfTab` / `shelfLimit` / `shelfMaxMegabytes` | `true` / `20` / `1024` | Enable the Shelf tab, set the item limit, and cap storage in MB (64 to 10240) |
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

On a Command Line Tools only setup, `swift test` can report zero tests. Point SwiftPM at the bundled Testing framework:
```bash
FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
INTEROP="$(xcode-select -p)/Library/Developer/usr/lib"
swift test -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
  -Xlinker -F"$FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$INTEROP"
```

Run the 153-layer logic harness:
```bash
bash scripts/build-logic-harness.sh
```

## License

Released under the MIT License. Refer to [LICENSE](LICENSE) for details.
