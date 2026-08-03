# Plan 007 — Idle UI: live agent strip beside the notch

Status: done (commit `c385b25`, signed `security-signing@monozen.local`).

## Goal
Make the closed idle chip a real "peek at your agentic workflow" surface on
the sides of the notch — live agents/processes at a glance, with customizable
facets (placement, display facets, density) — rather than a static
"Agents · N" pill.

## What changed
- `IslandMetrics`:
  - `IdleStyle` enum: `names`, `dots`, `summary`.
  - Pure geometry: `idleNameChipWidth`, `idleDotsChipWidth`,
    `idleSummaryChipWidth`, `idleShownChips` (truncation), `idleStripWidth`,
    `idleClosedWidth` (clamps to notch/expanded bounds).
- `NotchHUDConfig`: persisted facets `idleStyle` + `idleMaxChips` (clamped
  1…6), plus `clampedIdleMaxChips`.
- `NotchStatusView`:
  - Idle closed state renders `agentStrip` (chip per live agent, severity
    dot, `+N` overflow) instead of the generic pill; tap expands.
  - `closedPillWidth` sizes from the strip geometry.
- `SettingsView`: "Startup" section gains `Idle display` style picker and
  `Max agent chips` stepper; posts `.notchVisibilityChanged` so layout
  recomputes immediately.

## Gates
- `swift format lint --recursive --strict Sources Tests` — clean.
- `swift build` + `swift build -c release` — 0 warnings.
- `.kilo/LogicCheck.swift` — L5 RED-first block, `ALL PASS`.
- Installed + `launchctl kickstart -k` — island visible, event journal
  writing.

## Next
- In-pill (and approval) refinements; expanded panel design pass.