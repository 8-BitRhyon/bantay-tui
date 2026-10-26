# Bantay Strip: The Scrolling Multi-Agent Canvas for macOS
*An Agent-Centric Scrolling Window Manager & Spatial Canvas for AI Developer Workflows*

---

## 1. Executive Summary & Product Vision

### 1.1 The Thesis
Bantay was conceived as the **all-in-one starter kit for getting your agentic workflow together**.

Today, developers no longer work with a single text editor and a browser. An active agentic workflow commonly involves:
1. **Multiple autonomous CLI agents** (e.g., Claude Code in repo A, OpenCode/Codex in repo B, Kilo running test loops).
2. **AI-integrated GUI IDEs** (Antigravity IDE, Cursor, Windsurf).
3. **Live artifact surfaces** (Localhost browser dev servers, test runners, git diff viewers, terminal logs).

The bottleneck in multi-agent programming is no longer LLM generation speed—**it is human spatial orientation and cognitive overload ("What the fuck is going on right now?")**.

### 1.2 The Multi-Agent Window Dilemma
Current macOS window management paradigms catastrophically fail multi-agent development:
- **Overlapping / Freeform (Default macOS)**: Windows pile up like disorganized paper. When an agent blocks on an interactive approval (`[y/n]` prompt, file write confirmation), the user hears a chime or sees a notification, but must frantically ⌘-Tab or hunt through 10 open windows to find the exact terminal.
- **Grid Tiling (yabai, Amethyst, AeroSpace, Rectangle)**: Grid tilers split the screen every time a new agent window or preview opens ($1 \to 2 \to 3 \to 4$). By the 4th window, your code editor and terminal are crushed into 380px columns, wrapping code and rendering agent diffs unreadable.
- **Spaces / Virtual Desktops**: Switching between 5 full-screen Spaces separates context, hides agent progress states offscreen, and causes jarring transitions.

### 1.3 The Solution: The Scrolling Agent Canvas (Bantay Strip)
Inspired by the scrolling strip model of **PaperWM** (Linux), **niri** (Wayland), and **ChainYourMac** (macOS), **Bantay Strip** arranges every coding agent, terminal, and preview window side-by-side on an **endless horizontal strip**.

Opening one more agent terminal never shrinks the rest. Each window preserves its readable width (50%, 66%, or full width) and full display height. You navigate the strip with fluid trackpad gestures or vim-style shortcuts (`⌃⌥H` / `⌃⌥L`).

Crucially, **Bantay elevates this beyond generic window management by injecting agent intelligence**:
- **Agent Identity & State Halos**: Windows are tagged with live agent metadata (`claude`, `codex`, `antigravity`, `cursor`). The window borders glow with ambient status halos (Amber = Waiting for Approval, Cyan = Thinking/Generating, Green = Done, Red = Error).
- **Auto-Jump to Blocked Agent**: When the Dynamic Island alerts that an agent needs approval, pressing `⌃⌥A` (or clicking the Notch alert) smoothly spring-scrolls the strip directly to that agent's window and focuses it.
- **Pinned Master Columns**: Pin your primary IDE or Bantay Task Dispatcher to the left 50%, while sub-agents scroll smoothly on the right 50%.
- **Interactive Notch Radar**: The Dynamic Island HUD doubles as a clickable mini-map showing the spatial layout of your agent strip.

---

## 2. Core Feature Specifications

### Feature 1: The Infinite Horizontal Strip
- **Spatial Topology**: Windows sit in an ordered horizontal sequence $[C_0, C_1, C_2, \dots, C_{n-1}]$.
- **Zero Shrinking**: Windows maintain an assigned preset width (Default: 50% screen width; configurable to 33%, 66%, or 100%).
- **Viewport Window Placement**:
  $$\text{Target } X_i = \text{Screen.minX} + \sum_{k=0}^{i-1} (W_k + \text{gap}) - X_{\text{viewport}}$$
  Windows that fall outside $[\text{Screen.minX} - W_i, \text{Screen.maxX}]$ are kept offscreen, cleanly positioned without stutter.
- **Dock & Menu Bar Awareness**: Automatically calculates safe usable bounds around the macOS Dock and menu bar/notch.

### Feature 2: Agent-Aware Identification & Live Status Halos
- **Process-to-Agent Mapping**: Reuses Bantay's `AgentDetector` and `TerminalRegistry`. When a terminal or IDE window is created, Bantay scans the window's owner PID and child tty/subprocesses to tag the column with:
  - Agent family (`claude`, `codex`, `antigravity`, `cursor`, `opencode`, `copilot`, `kilo`).
  - Active project / working directory (`cwd`).
  - Execution state (`working`, `blocked`, `idle`, `completed`).
- **Floating Status Halo (NSWindow Overlay)**:
  - Lightweight border overlay rendered 1pt outside the focused/active agent window.
  - **Color Tokens (FLXDesignSystem)**:
    - 🟡 **Amber Pulse**: Needs human approval / interactive input (`AgentEventKind.accessRequest`).
    - ⚡ **Cyan Breathing Glow**: Active inference / execution (`AgentEventKind.progress`).
    - 🟢 **Emerald Pulse**: Run completed successfully (`AgentEventKind.completed`).
    - ⚪ **Muted Slate**: Idle / waiting for command.

### Feature 3: Smart Navigation & Approval Dispatch
- **Approval Auto-Center (`⌃⌥A` / Click Notch Alert)**:
  - Instantly computes $X_{\text{viewport}}$ required to bring the blocked agent's column into exact center view.
  - Triggers a physics-based spring animation to slide the strip into place.
  - Immediately gives focus to the target window and activates its terminal/app.
- **Keyboard Navigation (Vim & Arrow Bindings)**:
  - `⌃⌥H` / `⌃⌥←`: Focus column to the left.
  - `⌃⌥L` / `⌃⌥→`: Focus column to the right.
  - `⌃⌥⇧H` / `⌃⌥⇧L`: Move current column left / right on the strip.
  - `⌃⌥R`: Cycle column width (33% $\to$ 50% $\to$ 66% $\to$ 100%).
  - `⌃⌥C`: Center the focused column on the display.
  - `⌃⌥F`: Toggle full-width.
  - `⌃⌥1...9`: Jump directly to column 1 through 9.

### Feature 4: Column Stacks & Pairings
- **Stacked Agent Workstations**:
  - Pull a related window into the same column to share horizontal space vertically (e.g. Claude Code on top 70%, Git Diff or test log on bottom 30%).
  - Shortcut: `⌃⌥]` (stack with right column), `⌃⌥[` (stack with left column), `⌃⌥⇧]` (pop out).
- **Tabbed Columns**:
  - Convert a stacked column into tabs when each window requires full height.
  - Header tab bar indicates which agent/app is in the column with clickable tabs.

### Feature 5: Pinned Orchestration Columns
- **Pinned Left / Right**:
  - Pin one column (e.g., Primary IDE or Bantay Task Dispatcher) permanently to the left (`⌃⌥P`) or right (`⌃⌥⇧P`) edge.
  - The pinned column stays stationary at full height, while the remainder of the strip scrolls fluidly next to it.
  - Perfect for: "My primary IDE stays anchored on the left; my 3 background coding agents scroll on the right."

### Feature 6: Dynamic Island Mini-Map (Radar HUD)
- **Clickable Strip Indicator**:
  - When navigating or holding `⌃⌥`, a sleek frosted glass indicator appears in the Dynamic Island HUD (or floating top center).
  - Displays mini cards/icons for each column:
    - App icon + Agent glyph (`Claude`, `Gemini`, `Cursor`, `Terminal`).
    - Status badge (working, blocked, done).
    - Current viewport bracket showing what is currently on screen.
  - Clicking any column tile immediately springs the viewport directly to that window.

---

## 3. Technical Architecture & macOS System Integration

```
┌────────────────────────────────────────────────────────────────────────┐
│                          BANTAY NOTCH HUD                              │
│         [ Strip Mini-Map Radar ]  [ Live Agent Status Badges ]         │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ Notifications / Event Dispatch
┌───────────────────────────────────▼────────────────────────────────────┐
│                    BANTAY STRIP MANAGER (Swift)                        │
│  - StripLayoutEngine: Infinite horizontal coordinate geometry          │
│  - ViewportAnimator: CADisplayLink spring physics interpolation        │
│  - AgentWindowRegistry: Window-to-Agent classification & PID mapping   │
│  - OverlayRenderer: NSWindow status border halos & focus indicators    │
└───────────────────┬────────────────────────────────┬───────────────────┘
                    │                                │
┌───────────────────▼─────────────┐    ┌─────────────▼───────────────────┐
│     macOS Accessibility API     │    │        Global Event Tap         │
│  (AXUIElement / AXUIElementSet) │    │   (CGEventTap / NSEvent Monitor)│
│  - kAXPositionAttribute         │    │  - ⌃⌥HJKL & arrow navigation   │
│  - kAXSizeAttribute             │    │  - Trackpad 3-finger horizontal │
│  - kAXMainAttribute             │    │  - Approval jump (⌃⌥A)          │
└─────────────────────────────────┘    └─────────────────────────────────┘
```

### 3.1 Zero-SIP Requirement (100% Native Accessibility API)
Unlike yabai (which requires disabling macOS System Integrity Protection for space manipulation and window injection), **Bantay Strip uses standard macOS Accessibility (`AXUIElement`) APIs**:
- `AXUIElementCreateApplication(pid)`: Targets application by process ID.
- `AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &windows)`: Discovers application windows.
- `AXUIElementSetAttributeValue(window, kAXPositionAttribute, positionValue)`: Sets window $(x, y)$ coordinates.
- `AXUIElementSetAttributeValue(window, kAXSizeAttribute, sizeValue)`: Sets window $(w, h)$ dimensions.
- `AXUIElementSetAttributeValue(window, kAXMainAttribute, kCFBooleanTrue)`: Sets keyboard focus.

**Permission Profile**: Only requires the standard **macOS Accessibility** permission (the same permission Bantay already utilizes for focus management and keystroke safety).

### 3.2 Viewport Coordinates & Layout Mathematics
Let screen visible frame be $[X_{\text{screen}}, Y_{\text{screen}}, W_{\text{screen}}, H_{\text{screen}}]$.
Let gap between columns be $G = 12\text{pt}$.
Let padding from screen edges be $P = 12\text{pt}$.

For a list of columns $C_0, C_1, \dots, C_{m-1}$ with widths $W_0, W_1, \dots, W_{m-1}$:
1. Column left boundary in strip space:
   $$X_{\text{strip}}(0) = P$$
   $$X_{\text{strip}}(i) = X_{\text{strip}}(i-1) + W_{i-1} + G$$
2. Given viewport offset $X_{\text{vp}}$:
   $$X_{\text{screen}}(i) = X_{\text{screen}} + X_{\text{strip}}(i) - X_{\text{vp}}$$
3. Height and vertical alignment:
   $$Y_{\text{screen}}(i) = Y_{\text{screen}} + P$$
   $$H(i) = H_{\text{screen}} - 2P$$
4. **Visibility Optimization**:
   If $X_{\text{screen}}(i) + W_i < X_{\text{screen}} - 200$ or $X_{\text{screen}}(i) > X_{\text{screen}} + W_{\text{screen}} + 200$, the window is positioned offscreen or tagged as hidden to prevent window server compositing overhead.

### 3.3 Physics-Based Spring Animation
To match the tactile feel of macOS:
- We implement a damped harmonic oscillator (critically damped spring, $\zeta \approx 0.85$, $\omega_0 \approx 28$).
- Driven via `CADisplayLink` (ProMotion 120Hz locked on MacBook Pro Liquid Retina XDR displays).
- Allows interruptible scrolling: if the user taps `⌃⌥L` while the strip is still springing from `⌃⌥H`, the velocity seamlessly transitions without jarring snaps.

### 3.4 Integration with Bantay Event Pipeline
- `AgentEventManager.shared`: Listens to incoming agent events (`accessRequest`, `progress`, `completed`, `failed`).
- When `accessRequest` is received from `agent.pid`:
  1. Window registry flags corresponding column with `.needsApproval`.
  2. Floating overlay sets border to `#F59E0B` (Amber) with pulsing opacity.
  3. Dynamic Island displays the approval badge with shortcut hint `[⌃⌥A Jump]`.
  4. If user config `autoScrollOnApproval` is enabled, the strip immediately animates to center the blocked agent.

---

## 4. Proposed File Structure in BantayTUI

```
Sources/BantayTUI/
├── Strip/
│   ├── StripManager.swift             # Main coordinator, state machine, lifecycle
│   ├── StripLayoutEngine.swift        # Coordinate math, column sizing, boundaries
│   ├── StripWindowRegistry.swift      # AXUIElement discovery, PID-to-Agent resolution
│   ├── StripViewportAnimator.swift    # 120Hz CADisplayLink spring physics engine
│   ├── StripGestureInterceptor.swift   # CGEventTap for 3-finger swipe & hotkeys
│   ├── StripOverlayRenderer.swift     # Border halos (amber, cyan, green status rings)
│   ├── StripMiniMapHUD.swift          # Notch mini-map radar widget
│   └── StripConfiguration.swift       # Presets, gaps, pin settings, auto-jump options
```

---

## 5. Phased Implementation Roadmap

```
PHASE 1: Core Strip Engine
  ├── AXUIElement window tracking & positioning
  ├── Strip coordinate layout (50%, 66%, 100% width presets)
  ├── Keyboard navigation (⌃⌥HJKL / arrows)
  └── Spring animation loop (CADisplayLink)
         │
PHASE 2: Agent Intelligence & Status Halos
  ├── PID-to-Agent detection integration
  ├── Border overlay halos (Amber approval, Cyan progress, Green done)
  ├── ⌃⌥A auto-jump to blocked agent
  └── Settings panel integration in SettingsView.swift
         │
PHASE 3: Dynamic Island Radar & Trackpad Swipes
  ├── Notch HUD strip mini-map
  ├── Click-to-jump column navigation
  └── 3-finger fluid horizontal trackpad swipe
         │
PHASE 4: Advanced Workstations
  ├── Pinned master columns (IDE pinned left, agents scrolling right)
  ├── Stacks & tabbed columns (terminal + preview paired)
  └── Multi-display per-monitor strips
```

---

## 6. Key Verification Criteria & Guardrails

1. **Safety & Zero Disruption**:
   - Must never steal input or fire synthetic keystrokes while the user is typing.
   - Respects full screen apps and floating dialogs (Finder, Calculator, Permission prompts float naturally).
2. **Strict Concurrency & Linting**:
   - Swift 6 strict concurrency (`Sendable`, `@MainActor` isolation where UI is touched).
   - `swift format lint` passes with 0 warnings.
   - Max line length $\le 100$ characters.
3. **Pure Logic Testability**:
   - `StripLayoutEngine` math must be 100% pure Swift (no AppKit dependencies required for coordinate calculation).
   - Test suite integration into `.kilo/LogicCheck.swift` and `BantayTUILogicTests` verifying column math, scroll clamps, and state transitions.
