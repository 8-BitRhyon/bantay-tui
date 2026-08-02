# Plan 006: Spec-driven development discipline + adversarial test suite

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm its expected output. If a STOP condition
> appears, stop and report  -  do not improvise. When done, update your row in
> `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b3a29ef..HEAD -- .kilo/LogicCheck.swift`
> If the harness changed materially, re-baseline before adding cases.

## Status

- **Priority**: P1 (gate for every other plan; nothing ships without its RED→GREEN arc)
- **Effort**: M
- **Risk**: MED  -  it introduces the *rule* that code changes only land after failing tests
- **Depends on**: none
- **Category**: tests | dx
- **Planned at**: commit `b3a29ef`, 2026-08-02 (last modification: adversarial suite added above commit, see `git log`)
- **Issue**: none

## Why this matters

The repo's SDD problem: two test layers exist (`swift test`/XCTest — Xcode only, and the `.kilo/LogicCheck.swift` hand-rolled harness at CI Layer 3.5 which runs on CLI), but up to now both were used after the fact, asserting whatever the implementation happened to do. The user's requirement is **spec-driven and adversarial**: write the failing test for the spec's invariant **first**, implement, then deliberately try to break it (pollution, storms, degenerate geometry, nil/empty payloads, clock boundaries). This plan makes LogicCheck the *spec authority* that works in CommandLineTools, adds an adversarial corpus, and codifies the two real edge cases the corpus already flushed out.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Logic harness (CI Layer 3.5, runs here) | `swiftc -o /tmp/logic-check Sources/BantayTUI/AgentEventKind.swift Sources/BantayTUI/NotchHUDConfig.swift Sources/BantayTUI/HerdrSocketAdapter.swift Sources/BantayTUI/IslandMetrics.swift Sources/BantayTUI/AgentEventManager.swift .kilo/LogicCheck.swift && /tmp/logic-check` | `ALL PASS`, exit 0 |
| Format gating | `swift format lint --recursive --strict Sources Tests` | exit 0 |
| Build (Layer 2) | `swift build` | exit 0, **zero warnings** |
| Release (Layer 4) | `swift build -c release` | exit 0 |
| XCTest (Layer 3, Xcode only) | `swift test` | runs in CI only; not here |

`swift test` runs in CI on `macos-15`; locally we rely on the Logic harness + build gates.

## Current state (excerpts)

- `.kilo/LogicCheck.swift` ends with the tally logic:
```swift
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
```
- Everything before it is the check corpus, with persuasive probes now including a "MARK: - Adversarial (spec-driven: try to break)" section appended 4 (adversarial: status pollution A1, storm A2, sharded panes A3, degenerate geometry A4, variance-without-choices A5). Baseline after adding that section: 191 PASS, 2 FAIL (see Findings).

## Scope

**In scope**:
- `.kilo/LogicCheck.swift` — the shared spec-tests + adversarial corpus.
- `Tests/BantayTUILogicTests/*` — XCTest twin for the drawing/rare-argument tests that the harness cannot reach (Calendar/UI).
- New testable seams in `Sources/BantayTUI/` ONLY where the spec test needs a pure function that isn't testable today:
  - `IslandMetrics.windowFrame(...)` gains a bounds clamp (F2 below).
  - A dedicated `AgentEventManager` quiet-hours/mute/snooze gate (from 005) gets pure predicates.
- `plans/README.md` — status.

**Out of scope** (do NOT touch):
- Product UI files unless the specific seam above applies.
- CI workflow changes beyond adding the futures layer to `logic` job command line (that's already live today, keep it).

## Steps

### Step 1 (baseline) - transcript of today's harness

Replicat manual run until `ALL PASS` (exit 0). Then introspect:

```bash
/tmp/logic-check | rg -c '^PASS'      # count
/tmp/logic-check | rg -c '^FAIL'      # count
```

Expected on a clean tree: 191 PASS / 2 FAIL *today's adversarial corpus*; after this plan's fixes, only 0 FAIL (see Step 4).

### Step 2 - Findings from the adversarial run become tests

Both current FAILs are real behaviors that documentation got wrong:

**F1 — "silent re-show" only for the live pane.** `.kilo/LogicCheck.swift` (the A3 revival case) shows a vanished-then-re-added pane re-emits a `progress` event. This is *current code's* contract. The spec in README promises silent reappearance only for a pane that never left. Fix (CODE, small):
- In `AgentEventManager.update(from:lastSeenKinds:current:)`, when a previously-removed pane re-appears with the same `kind` as before it vanished, emit the `progress`/`accessRequest` row **with `playSound == false`** (silent), and add a spec-check asserting exactly that:
```swift
check(revival.events.allSatisfy { $0.playSound == false },
      "F1 resurrected pane re-emits silently")
check(revival.events.contains { $0.kind == .progress },
      "F1 resurrected pane still shows in roster stream")
```

**F2 — window larger than the display.** `windowFrame(screenFrame:size:scale:)` na vi group the fixed 504×560 center; on a 400×300 hypothetical screen it overflows (minX=-52, minY=-260).
- Fix (CODE): `windowFrame` clamps `size` to the screen: `w = min(size.width, screen.width)`, `h = min(size.height, screen.height)` **at least for the closed/expanded pill window** (keep the island chever trump). Add spec checks:

```swift
let fitted = IslandMetrics.windowFrame(screenFrame: CGRect(x: 0, y: 0, width: 400, height: 300), size: ws, scale: 1)
check(fitted.width <= 400 && fitted.height <= 300, "F2 window clamped to display")
check(fitted.minX >= 0 && fitted.minY >= 0, "F2 window fully on-screen")
```

Must land BEFORE Step 4 so the corpus goes all-green.

### Step 3 - write RED tests for remaining spec-related domains (before any code)

For each of 001-005's accepted criteria, add tests to `.kilo/LogicCheck.swift` (logic) or `Tests/BantayTUILogicTests/` (XCTest — Xcode-only but written now):

- **001 (controls)**: config setters persist (`islandEnabled`, `snoozedUntil`), `isSnoozed` at the past/now/future boundaries, snooze hides the island (a new pure `IslandMetrics.hideGate?`).
- **002**: Settings-state snapshot not used by logic (skip), `LaunchAgent.isInstalled/isLoaded` CLI-output parsing (3 output cases: loaded, not loaded, malformed).
- **003**: feed URL parse edge (trailing slash vs none).
- **004 (uninstall)**: pure deciders in script aren't testable from Swift; instead assert in a shell test via `bash -n` + a dry-run of the bootout/rm paths (file row `tests/setup_uninstall_spec.sh` with `set -e` and assertions on `launchctl` args echoed).
- **005**: `isWithinQuietHours` boundaries (22:00 start = true; 8:00 end = false; start==end = false; overnight), `isMuted` exact string.

Each of those must be **written and FAIL before the correlated implementation code is written**. If you are implementing 001's config and haven't yet written the `isSnoozed` boundary case, that's a process violation.

### Step 4 - adversarial ingest (the "try to break" set)

The corpus should grow, not shrink, per requirement. Keep adding:

- **Payload abuse**: whitespace/case status (done A1), nil title, nil choices+`.multi`, empty `choices: []` with `.choices`, `variance: "bogus"` string, `clear` on an empty pill, giant (100k-char) titles, unicode noise (CJK/emoji) in titles and sources, negative `playSound` (field is Bool — n/a).
- **Storm**: 100 flips (done A2), ramping 6-pane weave with panes dropping in/out, two sources flip-locking.
- **Clock**: TTL auto-clear with `Date()` near boundaries; midnight rollover for quiet-hours; `snoozedUntil` a second in the past/future.
- **Geometry**: 400×300 (done), 800×600 (becomes the *post-clamp* floor), scale 0.5/1/1.5/2/3/8 (done 8), near-infinite aux widths, split part-screen notch halves, `topInset` with `safeTop < 0`.
- **Files**: events.jsonl with a truncated line, a line longer than 4096 bytes, binary garbage, permission-denied file, file deleted mid-run (poll re-creates?).

Each new test is **RED-first**: add ==, observe FAIL, then implement.

### Step 5 - get the corpus green

- Fix F1, F2 (code).
- Re-run the harness → **ALL PASS**.
- Mirror the two fixes in `Tests/BantayTUILogicTests/` if the file refactors; else leave.

### Step 6 - gates

- `swift format lint --recursive --strict Sources Tests` → 0
- `swift build` → 0 warnings
- `swift build -c release` → 0
- harness → ALL PASS

## Test plan

- The harness **is** the test plan: 191+ assertions must be 0 FAIL.
- New pure predicates added (quiethours/mute in 005, window-fill in F2) are asserted both in the harness and (X-te) in `Tests/BantayTUILogicTests/...` for the axes that apply.
- The `scripts/` uninstall assert in 004 is shell-level: `bash -n scripts/setup.sh` plus a stub `launchctl` PATH run.

## Done criteria

- [ ] The 2 FAIL → 0; harness exit 0 prints ALL PASS
- [ ] F1 silent rebirth tested; F2 clamping tested
- [ ] No gate regressions (format/build/release)
- [ ] For every in-progress plan the operator implemented, the plan's README status row notes its RED phase artifacts (the failing test that first caused the fix)
- [ ] `plans/README.md` updated

## STOP conditions

- The `guard` in `update` that distinguishes "same pane, same kind, silent" from "new pane" isn't visible. Request a code review before implementing F1 — the semantics (silent-resurrect vs still-sound) are a product decision.
- If clamping `windowFrame` (F2) breaks the centered/backing-grid invariants that the harness today certifies (step "grid aligned at scale 8"), revert, STOP, report — do not un-pixel-align.
- No new /3: do not do any of this in the same commit as the feature work; RED and GREEN are separate steps.

## Maintenance notes

- Keep the harness in sync with `Tests/**`: CI runs XCTest on Xcode and the harness on CLI; a dev machine with Xcode runs all three.
- When `001-005` land, this file's "adversarial invariants" section grows; keep `A`-prefixed ids stable so TODO-lists and the README index can be certified.

One external doc worth citing in reviews: `DEV_PATH Phase 6.1` had planned exactly this ("add a harness that works without XCTest," checks on CLI) - see DEVELOPMENT_PLAN.md phase 6.1.