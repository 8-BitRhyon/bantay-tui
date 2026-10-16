# Plan 020: Semantic Activity Detection & Text Sanitization Pipeline

## Objective
Eliminate unintelligible plain text, raw JSON fragments, ANSI escape codes, terminal spinner characters, and hostname fallbacks across Bantay-TUI, replacing them with accurate, human-readable semantic action verbs across the Dynamic Island, Notch HUD, shelf, and macOS menu bar.

---

## Architecture & Work Breakdown

### Task 1: Universal Anti-Garbage Engine in `IslandMetrics.cleanHUDText`
- **File:** `Sources/BantayTUI/IslandMetrics.swift`
- Integrate `stripControlCharacters` directly inside `cleanHUDText`.
- Strip ANSI CSI sequences (`\u{1b}\[[0-9;?]*[a-zA-Z]`), OSC sequences (`\u{1b}\][^\u{07}\u{1b}]*(\u{07}|\u{1b}\\)`), and bare 2-character escapes.
- Strip terminal spinner braille characters (`[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]`), progress bar brackets (`\[=+>?\s*\]\s*\d+%?`), and carriage-return fragments.
- Strip ISO timestamps (`\d{4}-\d{2}-\d{2}T[0-9:.]+Z?`), log prefixes (`INFO`, `WARN`, `ERROR`, `DEBUG`, `TRACE`), and run IDs.
- Detect and reject unparsed JSON blobs (`{...}`) and diff blocks (`@@ -...`, `[diff_block_start]`).
- Neutralize hostname fallbacks (`*.local`), bare shells (`zsh`, `bash`, `sh`, `fish`, `node`), returning a sanitized fallback.

### Task 2: Enhanced Semantic Intent Extraction in `AgentDetector.readableLine`
- **File:** `Sources/BantayTUI/AgentDetector.swift`
- **Zero Raw JSON Guarantee:** Delete `if snippet.hasPrefix("{") { return String(snippet.prefix(160)) }`. Unparsed JSON lines return `nil` to allow backward scanning to find the actual prior tool call or user input.
- **Universal Tool-Call Parser:**
  - Support `tool_calls` (Antigravity, OpenAI), `tool_use` (Claude Code), `action`/`event` (Goose), and command execution blocks.
  - Deep-unquote arguments and tool summaries (stripping escaped outer quotes `\"`).
- **Command Semantic Translation:**
  - Test suites (`swift test`, `cargo test`, `pytest`, `npm test`, `jest`) $\rightarrow$ `"Running tests"`
  - Builds (`swift build`, `cargo build`, `npm run build`) $\rightarrow$ `"Building project"`
  - Git (`git commit` $\rightarrow$ `"Committing changes"`, `git push` $\rightarrow$ `"Pushing to git"`, `git status`/`diff` $\rightarrow$ `"Checking git status"`)
  - File search (`grep`, `rg`, `find`) $\rightarrow$ `"Searching files"`
- **Skip List Expansion:**
  - Skip `ERROR_MESSAGE`, `SYSTEM_MESSAGE`, `CONVERSATION_HISTORY`, `KNOWLEDGE_ARTIFACTS`.
  - Skip daemon maintenance logs (`service=marketplace`, `cleanup prune=`, `message=init count=`).

### Task 3: Display-Site Defense in Depth
- **Files:**
  - `Sources/BantayTUI/NotchStatusView.swift`: Wrap all title/reason text views (`CompactIslandView`, `HUDExpandedView`, `HUDMiniView`, `MascotTooltip`) with `cleanHUDText`.
  - `Sources/BantayTUI/DynamicIslandApp.swift`: Wrap menu bar agent status items and approval titles with `cleanHUDText`.

### Task 4: Unit Tests & Logic Harness Validation
- **Files:**
  - `Tests/BantayTUILogicTests/IslandMetricsTests.swift`: Add comprehensive test suite covering ANSI stripping, spinner suppression, JSON rejection, timestamp stripping, and hostname neutralization.
  - `.kilo/LogicCheck.swift`: Add Layer 150 verifying the semantic parser against raw transcript lines.
  - Run `scripts/build-logic-harness.sh`, `swift test`, and `swift-format`.

---

## Verification Criteria
1. `scripts/build-logic-harness.sh` passes all layers.
2. `swift test` passes with zero failures.
3. Strict swift format checks pass with no line exceeding 100 characters.
4. Release binary builds successfully and LaunchAgent service runs cleanly.
