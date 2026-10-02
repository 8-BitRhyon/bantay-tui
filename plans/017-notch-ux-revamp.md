# Implementation Plan 017 — Comprehensive Notch UI & UX Revamp

> **Objective:** Execute the core visual, architectural, and ergonomic improvements identified in `NOTCH_UX_COMPREHENSIVE_EVALUATION.md`.  
> **Key Focus Areas:**  
> 1. Tab Bar Truncation Fix (remove orphaned "Workspace" button).  
> 2. Elevation & Visual Contrast (OLED dark glass gradient + 22% white rim highlight + ambient drop shadow).  
> 3. Notes Scratchpad Overhaul (full-height layout + header toolbar with word/character count, copy, clear, and autosave status).  
> 4. Header Bar Polish (active event badge encapsulation).

---

## Technical Tasks

### 1. `Sources/BantayTUI/NotchStatusView.swift`
- **Tab Bar (`shelfTabBar`)**:
  - Remove orphaned `Button` "Workspace" (lines 1618–1649) that caused the `Wor...` truncation.
  - Remove unused `@State private var groupByWorkspace`.
  - Ensure tab buttons distribute cleanly across `expandedWidth: 456`.
- **Surface Elevation & Contrast (`islandBackground`)**:
  - Replace flat black with OLED dark glass gradient:
    `LinearGradient(colors: [Color(hex: "12141D"), Color(hex: "08090E")], startPoint: .top, endPoint: .bottom)`.
  - Update `spendStrokeColor` from `0.09` to `0.22` white opacity when `isExpanded` so the border is clearly defined against dark editors.
  - Add inner rim highlight overlay at the top edge (`LinearGradient(colors: [.white.opacity(0.12), .clear], ...)`).
  - Add dual drop shadow (`Color.black.opacity(0.50)`, radius 16, y 8) immediately after `.clipped()` so the shadow floats outside into the transparent window buffer.
- **Notes Tab Overhaul (`notesContent`)**:
  - Replace hardcoded `height: 96` with `maxHeight: .infinity`.
  - Add a dedicated Scratchpad toolbar with word count, character count, autosave badge, Copy button (with animated checkmark feedback), and Clear button.
  - Add styled inset card with subtle border and placeholder text.
- **Header Bar Polish (`headerBar`)**:
  - Wrap the active event title in a capsule badge with cyan activity dot and tooltip, preventing it from looking like a broken input field.

---

## Verification Plan

1. **Linting**:
   - `swift format lint --strict Sources/BantayTUI/NotchStatusView.swift`
2. **Logic Harness**:
   - `bash scripts/build-logic-harness.sh` (verify all 149 layers continue to pass)
3. **Unit Tests**:
   - `swift test`
4. **Binary Build & Daemon Refresh**:
   - `swift build -c release`
   - `bash scripts/setup.sh`
   - Restart live process and verify zero regressions.
