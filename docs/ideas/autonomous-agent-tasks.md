# Autonomous Task Dispatcher & Contextual Workspaces (Directions A & B)

## Problem Statement
*How might we enable tasks in Bantay-TUI to function as executable triggers that dispatch prompts to targeted AI agents (`@claude`, `@codex`, `@pi`, `@antigravity`, `@kilo`, `@herdr`) across both multiplexer TUIs (herdr, tmux, zellij) and GUI desktop apps (Antigravity IDE, Codex App, Cursor, Claude Desktop), while providing robust quota/budget tracking and project workspace binding?*

---

## Recommended Direction

### 1. 🤖 Autonomous Task Dispatch Engine (Direction A)
- **Targeted Prompt Dispatch**:
  - Tasks formatted as `@agentName prompt text` (e.g. `@claude fix auth tests`) gain a **▶ Run** button in the task widget.
  - Clicking **▶ Run** dispatches the prompt into the target agent's active multiplexer pane via `ControlGateway` / `HerdrSocketAdapter` (`agent.prompt` or `pane.send_keys`), or activates the GUI application via `StandaloneAgentDispatcher` (Antigravity IDE, Codex App, Cursor).
- **Execution State Machine**:
  - `Pending` ➔ `Dispatched` ➔ `Working ⚡` ➔ `Needs Approval ⚠️` ➔ `Completed ✅` / `Failed ❌`.
  - When the linked agent emits a `.completed` or `.done` hook event, Bantay **automatically marks the task complete** and awards Mascot XP.
- **Configurable Settings**:
  - **Dispatch Mode**: Default is **Manual** (user clicks ▶ Run on the task card). Settings toggle available for **Auto-run on Creation**.
  - **Focus Behavior**: Default is **Silent Background Dispatch** (agent works without stealing window focus). Settings toggle available for **Auto-focus Terminal/App on Dispatch**.

### 2. 🌲 Contextual Workspaces & Project Binding (Direction B)
- **Branch & Directory Auto-Binding**:
  - Tasks created within a workspace automatically attach the current `cwd` and `git branch` (derived from `ProjectContext`).
  - Active terminal or IDE window switches dynamically filter the task list to display tasks relevant to the current project/repository.
- **Subtask & Goal Checklists**:
  - Support nested checklists under parent goals for multi-step agent refactorings.

### 3. 📊 Robust Quota & Budget Velocity Monitor
- **Multi-Agent Usage Ledger**:
  - Consolidates SQLite usage data from `KiloUsageAdapter` (`kilo.db`), JSONL transcript feeds (`~/.claude/projects`, `~/.codex/sessions`, `~/.gemini/antigravity-ide/brain`, `~/.pi/agent/sessions`), and `QuotaAxiTracker`.
- **Budget Alarming & Quota Warnings**:
  - Real-time tracking against daily/monthly USD spending caps (`usageBudgetUSD`).
  - Triggers ambient notch alerts (glow pulse & mascot warnings) when token burn rate exceeds threshold or when remaining quota drops below 20%.

---

## Key Assumptions to Validate

- [ ] **Assumption 1**: Prompts dispatched to multiplexer panes (`herdr`, `tmux`, `zellij`) do not interfere with half-typed shell inputs.
- [ ] **Assumption 2**: Desktop GUI applications (Antigravity IDE, Codex App, Cursor) can receive dispatched prompts via pasteboard copy and activation notifications reliably.
- [ ] **Assumption 3**: Transcript-based token and cost tracking (`UsageTracker`) matches real billing metrics across all supported agent families.

---

## MVP Scope & Implementation Roadmap

### Phase 1: Direction A — Autonomous Dispatcher & State Machine
- **`TaskModel.swift`**: Add `executionState` (`pending`, `dispatched`, `working`, `blocked`, `completed`, `failed`), `linkedPaneID`, and `dispatchedAt`.
- **`TaskDispatcher.swift`**: Create core dispatcher resolving target agents (`@claude`, `@codex`, `@pi`, `@antigravity`, `@herdr`, `@kilo`, etc.), routing via `ControlGateway` or `StandaloneAgentDispatcher`.
- **`TaskWidgetView.swift`**: Add **▶ Run** dispatch button, live **Working...** state, and **Focus Pane (⌘F)** action.
- **`NotchHUDConfig.swift`**: Add `autoDispatchTasks` (default: `false`) and `focusTerminalOnDispatch` (default: `false`).

### Phase 2: Direction B — Contextual Workspaces & Subtasks
- **Project Binding**: Tasks store `cwd` and `gitBranch`. Widget adds a "This Project" filter toggle.
- **Subtask Trees**: Support sub-items under a parent task with progress bars.

### Phase 3: Quota & Budget Hardening
- Audit and refine `QuotaAxiTracker` and `UsageTracker` to surface exact spend percentages, burn rate forecasts, and budget overflow warnings.

---

## Not Doing (and Why for Now)

- **Automatic Multi-Agent Prompt Auto-Decomposition** — *User explicitly assigns `@agent` in the task title; no AI meta-planner auto-splitting tasks in MVP.*
- **Mobile Remote App (Direction C)** — *Deferred until Direction A & B desktop experience is 100% solid and verified.*
