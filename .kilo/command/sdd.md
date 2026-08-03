---
description: Spec-driven development with adversarial tests for a Bantay-UI plan
---
# Spec-Driven Development (SDD)  -  the Bantayi-TUI build rule

You are executing a Bantay-TUI plan the **spec-driven way** (see
`plans/006-test-harness-sdd.md` for the harness contract, and
`plans/000-ux-research.md` for the UX baseline these tests encode).

`$ARGUMENTS` = plan(s) to work on. Default: the highest-priority TODO row in
`plans/README.md`.

## 0. Preconditions (2 minutes)

1. Run `git rev-parse --short HEAD` and read that plan's "Drift check (run
   first)". If the in-scope files moved away from the plan's "Current state"
   excerpts, STOP and report — do not improvise.
2. Read the plan's "Acceptance/done criteria" and the "Why".
3. Load the Logic harness once so you know today's baseline:
   `swiftc -o /tmp/logic-check Sources/BantayTUI/AgentEventKind.swift Sources/BantayTUI/NotchHUDConfig.swift Sources/BantayTUI/HerdrSocketAdapter.swift Sources/BantayTUI/IslandMetrics.swift Sources/BantayTUI/AgentEventManager.swift .kilo/LogicCheck.swift` then run `/tmp/logic-check`. Record the PASS/FAIL counts.
4. Gates: CI is 5 layers — `swift format lint --recursive --strict Sources Tests`
   (1), `swift build` zero-warnings (2), `swift test` (Xcode-only, CI may run it),
   `swift build -c release` (4). Test locally, gate on 1/2/4 + the harness.

## RED phase - write the tests that prove the spec (code first)

"Works on paper" is not the bar. For every acceptance criterion in the plan:

1. Add a failing test first — in `.kilo/LogicCheck.swift` if it's logic/
   geometry/config logic (this runs on CLI here), or in
   `Tests/BantayTUILogicTests/` for XCTest the harness can't reach.
2. Enumerate adversarial variants explicitly — try to break it, don't just
   test the happy path. The agreed attack list (grow it): whitespace/case
   status pollution, event storms (≥100 flips), pane shards and vanish/re-add,
   degenerate screens (smaller than the fixed 504×560 window), scale 0.5–8,
   nil/empty/unicode/binary inputs, truncated/giant/garbage JSONL lines, midnight
   and `start==end` boundaries for quiet-hours, snoozed a second in the past
   and future, empty `choices` with `.choices`, unknown `variance` strings.
3. Run the harness/`swift build` **and insist on seeing the new tests FAIL**.
   If they pass before you wrote implementation for them, your test is
   redundant or your assumption is wrong — STOP and re-read the spec.
4. Name the artifacts: note the plan's README status row gains a "RED" item
   listing the failing test ids.

## GREEN - minimal implementation

Implement the smallest correct change for the failing spec. Do not expand
scope. Run the gate set:

- `/tmp/logic-check` → exit 0, `ALL PASS`
- `swift format lint --recursive --strict Sources Tests` → 0
- `swift build` → 0 warnings
- `swift build -c release` → 0

If any gate fails twice, STOP, report (do not bludgeon the code).

## HARDEN - antagonist review pass

Once GREEN, run the adversarial suite from plan 006 step 4 again against
your NEW logic specifically:
- Cut/paste each happy path into a degenerate input and confirm the harness
  guards it.
- Re-check the two known edge regressions F1 (silent resurrect) and
  F2 (window<=display clamp) if they touch your plan.

## Close out

- Update `plans/README.md` status row for your plan: DONE (with the note
  "RED: <ids>" if you delivered them), or BLOCKED + one-line reason.
- Do not commit, push, or open a PR unless explicitly asked.

Reference files: plans/006-test-harness-sdd.md (harness contract),
plans/000-ux-research.md (the standard being enforced).