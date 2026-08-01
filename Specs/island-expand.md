# Island Expand Animation — Spec

Applies to the hover-expand of the Bantay-TUI notch island.

## Problem

The island currently resizes its `NSPanel` first (instant `setFrame`), then
springs the content. The window's edges and the pill's coordinate frame jump
during phase one, so expansion reads as "grows from the left, then from the
right" — asymmetric. The resize-from-layout path also caused a SIGABRT
constraint cycle (fixed earlier by "resize-then-spring", which is the current
two-phase workaround).

## Reference architecture (researched)

BoringNotch (`sizing/matters.swift`: fixed 640×210 window) and Notchly
(`SkyLightOverlayController.swift`: fixed 456×280 window) both:

1. Create the island panel **once at a fixed size** — the maximum expanded
   size, centered on the screen top. The window frame is never changed by
   expand/collapse.
2. Draw the closed pill **centered** inside that window.
3. Animate **only the content** (pill width/height) with a SwiftUI spring:
   Notchly `.smooth(duration: 0.42, extraBounce: 0)`; BoringNotch
   `.spring(.bouncy(duration: 0.4))`.
4. Make the transparent margins click/hover-through
   (`Color.clear.allowsHitTesting(false)`).

Symmetric expansion is then a structural invariant: the window is centered on
the screen, the pill is centered in the window, and the spring changes only the
pill's size around its center.

## Design

- Window: fixed `504 × 560` pt (`IslandMetrics.windowSize()`), centered via
  `IslandMetrics.windowFrame(screenFrame:size:scale:)`, aligned to the backing
  pixel grid.
- Content: `ZStack` centered in the window; pill frame
  `width: closed 227 | expanded 456`, height per state, spring-animated with
  `withAnimation`.
- `expandTo(_:)` performs **no window frame mutation** — it only springs the
  content state.
- Hover cooldown 150 ms; hover scale 1.02 (closed) / 1.012 (expanded),
  anchored `.top` (Notchly parity).
- `prefers-reduced-motion`: `.linear(duration: 0.1)`, no spring, no bounce.

## Invariants (tested)

1. **Fixed window**: window size is identical in closed and expanded states
   and independent of agent count.
2. **No resize on expand**: the expand path contains no frame mutation.
3. **Symmetric morph**: closed and expanded pill centers equal the window
   center (`centeredContentX`), so the morph is symmetric around the notch.
4. **Backing grid**: window origin/edges land on the backing pixel grid for
   any scale ≥ 1.
5. **Notchless fallback**: no notch → closed pill width `211`.
6. **Oversized notch clamp**: closed pill width never exceeds the expanded
   width.
7. **Height cap**: expanded height is capped at `560` for any agent count.
8. **Zero-agent guard**: with no agents the island does not expand on hover.
9. **Collapse on empty**: expanding roster emptying collapses the island and
   cancels an in-flight prompt.
10. **Hover cooldown**: expansion fires only after 150 ms of sustained hover;
    early leave cancels it.
11. **Reduced motion**: motion-reduced environments use linear animation.
12. **Display changes**: reposition centers on the window's own screen
    (multi-display safe).
13. **Event priority preserved**: persistent event pill still shows in the
    closed state; expanded roster header still shows the event title.
14. **Composing survives roster churn** unless the composing agent's pane
    disappears.

## Edge cases

- Top-inset fallbacks: safe area → menu bar height → 0.
- Extreme roster counts (0, 1, many) with height capped.
- Fractional screen widths and non-integer backing scales.
- Rapid hover in/out/in (single expansion, no flicker).
- Event arrival while expanded (header title, no collapse).
- Window height taller than short displays (560 fits all ≥ 720 px screens).
