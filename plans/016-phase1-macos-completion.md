# Plan 016 — Phase 1: macOS completion & hardening (spec-driven stability, distribution, control-plane UI, multi-display/a11y)

Status: **proposed** (executor: planning only; no code lands until this plan's RED tests are written and observed FAIL, per `plans/006-test-harness-sdd.md`). Produced 2026-08-04 against `main` @ `544a68a`.

## Why

Phase 1 of the roadmap ratified in `plans/015-ecosystem-architecture.md` is the macOS completion pass: the app is feature-complete (plans 001–014 shipped, F1–F14 in) but still (a) has four known stability defects — a race-prone diff-stat cache (`NotchStatusView.swift:31,402-428`), pin state destroyed by every collapse (`NotchStatusView.swift:1663-1668`), synchronous `Process.waitUntilExit` on the main actor at several call sites (`HerdrSocketAdapter.swift:52-69`, `DynamicIslandApp.swift:750-756`), and a hook-merge that can destroy a user's `~/.claude/settings.json` on a corrupt/foreign read (`SettingsView.swift:535-540`); (b) has no update path (Sparkle still `TODO` in `plans/README.md:21`); (c) under-delivers the "see without the terminal" promise (peek is a 6-line inline tail, `NotchStatusView.swift:1212-1222`, no diff preview, no rate signal); and (d) is unverified on notch-less displays and unpolished for VoiceOver/keyboard. Every item below is failure-aware: the RED tests enumerate the ways the naive fix breaks, and the STOP conditions name the product decisions a fix cannot guess.

## Done criteria (verifiable acceptance list)

- [ ] **Harness**: `.kilo/LogicCheck.swift` grows L41–L50 blocks; each block is observed **RED first** (its FAIL logged in `plans/README.md` before the correlated code lands), final state `ALL PASS`, exit 0, check count ≥ 230 (194 today).
- [ ] **Gates**: `swift format lint --recursive --strict Sources Tests` exit 0; `swift build` and `swift build -c release` zero warnings; `swift test` green on CI Layer 3 (XCTest twins for the process/panel/updater items).
- [ ] **CI**: `ci.yml` `logic` + `logic13` compile lists updated for every new harness-compiled source file; both macOS 15 and macOS 13/Intel legs green; smoke job stays alive 10s.
- [ ] **1a** — diff stat for agent A shows the value for A's *current* cwd after A moves `/repo1` → `/repo2` (verified live); no stale-value flip-flop under rapid cwd churn; cache prunes dead (id, cwd) keys.
- [ ] **1b** — pin survives collapse → re-expand within a session; survives app relaunch (config-persisted); clears on explicit unpin and (per decision) on zero agents.
- [ ] **1c** — 60s of polling with 10 agents and repeated approve/deny yields zero main-actor stalls (no beachball; `RunLoop` responsive); every `waitUntilExit` main-actor call site eliminated (audit list in §1c is empty at the end).
- [ ] **1d** — installing/uninstalling the Claude hook preserves a foreign `PermissionPrompt` entry, a foreign hook sharing an entry, a malformed-but-foreign `hooks` value, and never writes `{}` over a file that failed to parse.
- [ ] **2** — "Check for Updates…" menu item + Settings "Updates" section exist; feed URL constant points at the placeholder appcast; `automaticallyChecksForUpdates` defaults **false**; release workflow emits `appcast.xml` when signing secrets exist and degrades to ad-hoc + documented Gatekeeper bypass otherwise; cask remains `auto_updates true`.
- [ ] **3** — peek overlay shows ≥100 lines of `pane read` output and a `git diff` preview, both capped and screen-clamped; rate indicator renders `tokens/min` with a warn color when over threshold; global ⌥Space (existing) + opt-in ⌥Approve/⌥Deny/⌥Snooze hotkeys work or degrade to menu-only when Input Monitoring is untrusted.
- [ ] **4** — on an external/no-notch display (`safeAreaInsets.top == 0`) the pill is centered below the menu bar and stays put through hot-plug/clamshell cycles (ghost re-anchor, L17, still passes); VoiceOver traverses the expanded roster and every button has a label; keyboard-only traversal (Tab/arrows/Enter) reaches approve/deny; no text opacity < 0.55 remains except on deliberately secondary glyphs.
- [ ] `plans/README.md` row 016 added: status + RED artifacts noted.

## Work items

### 1c — Non-blocking async process runners (foundation; do FIRST)

**Why here first**: 1a, 3a, 3c, and the uninstall path all route subprocess I/O through the same leak; fixing the runner once unblocks the rest.

**Audit of `waitUntilExit` / blocking `runHerdr` call sites** (verified by grep):

| Site | Blocking call | Caller context | Today |
|---|---|---|---|
| `HerdrSocketAdapter.swift:52-69` `runHerdr` | `waitUntilExit()` + lazy pipe drain | shared by everything below | sync, up to `timeout` s |
| `HerdrSocketAdapter.swift:71-76` `paneFocus` | CLI fallback `runHerdr` | SwiftUI button closures → `Task {}` inherits **MainActor** | blocks main up to 1s |
| `HerdrSocketAdapter.swift:82-84` `agentPrompt` | `runHerdr` direct, **no Task wrapper** | `NotchStatusView.swift:1781` `submitPrompt` | blocks main up to 1s |
| `HerdrSocketAdapter.swift:87-96` `sendKeys` | CLI fallback `runHerdr` | approve/deny/choice/stop via `AgentEventManager.performAction` (`:740-752`, detached ✓) but `sendLine`/`prompt` paths not | mixed |
| `HerdrSocketAdapter.swift:151-164` `listPanes` | `runHerdr` ×2 variants | protocol seam (`PlexerAdapter.swift:52-57`) | sync |
| `HerdrSocketAdapter.swift:244-246` `captureTail` fallback | `runHerdr` inline in `async` fn | `fetchPeek` is `Task.detached` (`NotchStatusView.swift:378`) | safe today, latent if called from main |
| `DynamicIslandApp.swift:750-756` `uninstallPrompt` | `waitUntilExit()` on `/bin/bash setup.sh --uninstall` | menu action | blocks main for script duration |
| `LaunchAgent.swift:16-29` `processRunner` | `waitUntilExit()` on `launchctl` | short; called from `isLoaded()` | acceptable but should share the runner |
| `AgentDetector.swift:166` | `waitUntilExit()` | already in `Task.detached` (`AgentEventManager.swift:566`) | safe |

**Implementation**:
- New `Sources/BantayTUI/ProcessRunner.swift`: `nonisolated enum ProcessRunner` with
  `static func run(executableURL:arguments:timeout:environment:) async -> ProcessResult`
  (`ProcessResult { status: Int32, stdout: String, stderr: String }`). Wait via continuation; drain stdout **concurrently** with execution (readabilityHandler or a parallel reader task) so >64KB output cannot deadlock; on timeout `terminate()` + wait, return partial output. Add `static func launch(executableURL:arguments:)` (fire-and-forget, terminationHandler-based cleanup) for approve/deny/keys where the caller doesn't need output.
- Rewire: `runHerdr` becomes `runHerdrAsync`; `agentPrompt`, `sendLine`, `paneFocus`, `sendKeys` become `async` (socket path already async; CLI fallback `await runHerdrAsync`); `listPanes` becomes async; `captureTail` fallback awaits the same runner; `uninstallPrompt` spawns a detached task and disables the button meanwhile; `NotchStatusView.fetchDiffStats` (item 1a) uses `ProcessRunner.run` with a timeout.
- Keep the `PlexerAdapter` protocol signatures where possible (`sendLine`, `listPanes` are protocol members, `PlexerAdapter.swift:52-57`): implement them non-blocking internally (spawn-and-forget / detached). If the protocol must become async, **stop** (see STOP conditions — the protocol is the D2 seam for tmux/zellij in 017).
- `ci.yml` note: if `ProcessRunner.swift` is added to the harness compile list, update **both** `logic` (`:57-72`) and `logic13` (`:142-157`) steps; prefer keeping it out of the pure harness and testing it in the XCTest layer.

**Pure state for testability**: none new beyond `runHerdrAsync` argument composition; the timeout clamp `ProcessRunner.clampedTimeout(_:)` and the existing `paneListCommandVariants()` (L27) stay pure.

**RED tests**:
- **L43 (Logic, harness)**: `clampedTimeout` bounds (negative/zero/huge → clamped); `paneListCommandVariants` still exact (already L27 — re-assert unchanged after async migration).
- **L43-X (XCTest, `Tests/BantayTUILogicTests/AsyncProcessTests.swift`)**: `/bin/echo` round-trip status 0; `/usr/bin/false` status ≠ 0; timeout on `sleep 30` returns ≤ 2s and `status` reflects termination; 1 MB stdout drains without deadlock (the `waitUntilExit`-before-read bug the old `runHerdr` has); non-existent executable → error, not hang. Write these RED, then implement.

**Failure modes & gaps**: pipe-fill deadlock (must drain while running); zombie processes on timeout (terminate + `wait`); timeout too short for a cold herdr start (herdr `agent list` can exceed 3s on first run — use the existing `timeout` default but make it injectable); `PATH`-relative `"herdr"` resolution already handled by `candidateHerdrPaths` (`HerdrSocketAdapter.swift:28-50`) — the runner must receive an absolute URL, never a bare name; the uninstall script must not be killed mid-write by the 3s default (use a long/no timeout for uninstall specifically); double-fire: approve re-entrancy is already guarded by `resolvingPanes` (`AgentEventManager.swift:141-144`) — the async migration must not bypass it; detached-task lifetime vs window teardown (cancellation on `stop()`/`stopCapture()` must terminate armed wait processes — already in `stopCapture`, extend to the new runner).

**Effort**: M. **Needs Xcode**: yes (XCTest spawn/timeout/deadlock twins).

### 1a — Diff-stat cache invalidation + directory-keyed matching

**Current behavior (verified)**: `diffStats: [String: String]` is keyed by `agent.id` (`NotchStatusView.swift:31`); the "partial fix" is `.onChange(of: agent.cwd) { diffStats[agent.id] = nil; fetchDiffStats(agent) }` (`:1573-1576`). Two defects: (1) **write race** — the in-flight task for the old cwd can complete after the new-cwd task and, because the write guard is `if self.diffStats[agent.id] == nil` (`:423`), a late-arriving old-cwd result lands first and the new-cwd result is dropped, leaving the row showing `/repo1`'s diff while the agent is in `/repo2`; (2) **id collision** — `AgentSnapshot.id = paneId ?? agent` (`AgentEventManager.swift:403`); standalone agents have `paneId == nil`, so two different `claude` processes on different cwds share one cache slot and flip-flop. Also `fetchDiffStats` has **no timeout** (`:404-412`) — a git process in a huge/mounted repo can hang forever.

**Implementation**:
- New pure `struct DiffStatCacheKey: Hashable, Sendable` (id + cwd) and `enum DiffStatCache` in `IslandMetrics.swift` (harness-compiled): `static func prune(_ cache: [DiffStatCacheKey: String], liveKeys: Set<DiffStatCacheKey>) -> [DiffStatCacheKey: String]` (drop stale (id, cwd) keys on write); `static func parseShortstat(_ raw: String) -> String?` — hoist the regex from `:418-419` (returns `"+N −M"` or nil on no-insertion/no-deletion/empty).
- `NotchStatusView`: `@State private var diffStats: [DiffStatCacheKey: String]`; `fetchDiffStats` guards on the composite key, runs through `ProcessRunner.run` (1c) with a timeout, writes keyed by the captured (id, cwd), then prunes. The `.onChange(of: agent.cwd)` handler keeps invalidating the read path but no longer needs a manual dict clear — it becomes `fetchDiffStats(agent)` only (the key change does the invalidation), removing the race at the source.
- Render site (`:1537-1545`) looks up `diffStats[DiffStatCacheKey(id: agent.id, cwd: agent.cwd)]`.

**RED tests**:
- **L41 (Logic)**: `DiffStatCacheKey` equality (same id+cwd equal; same id different cwd not); `parseShortstat` on `" 1 file changed, 2 insertions(+), 3 deletions(-)"` → `"+2 −3"`, insertion-only, deletion-only, empty/garbage → nil; `prune` removes only dead keys and never the live one; the simulated race: two writes for id=A under cwd1/cwd2, applied in any order to a keyed cache, always leave `cache[A:cwd2]` correct.
- **L41-X (XCTest, optional)**: `ProcessRunner.run` against a real git repo fixture returns a parseable shortstat and a non-repo returns empty.

**Failure modes & gaps**: git missing / not on `PATH` (empty output → nil → row hides the meter, correct default); non-UTF8 diff output; cwd with spaces/`\n` in the key (composite key is opaque — safe); permission-denied cwd (git stderr → `/dev/null`, empty stdout → nil); a git repo so large `git diff` exceeds the timeout (runner returns partial → parse nil → hidden, no hang); key growth when one agent churns many cwds (prune bounds it); `agent.cwd` toggling between two values every poll (thrash — the keyed cache makes every flip a refetch; acceptable, note it); iOS/macOS `String` hashing in `@State` dict is fine (Hashable). The old crash-class ("agent vanished while task in flight") is already guarded by the MainActor write check — keep that guard, keyed.

**Effort**: S–M. **Swift-only** (harness covers the pure parts).

### 1b — Pin state persistence across collapse/expand (and relaunch)

**Current behavior (verified)**: `@State isPinned` (`:23`); `expandTo(_ expanded:)` does `if !expanded { isPinned = false }` (`:1666`). So the pin is wiped on *every* collapse — hover exit, hotkey toggle, and the zero-agents auto-collapse (`handleAgentsChange` → `shouldCollapse`, `:1759-1763`). The pin button (`:1152-1163`) toggles `@State` only.

**Decision to make (product)**: pin is a "keep expanded" intent. Proposed semantics: persist across collapse for **user-driven** reasons (hover exit, hotkey collapse, display hot-swap re-anchor) and across **relaunch**; clear on explicit unpin and on **zero agents** (nothing to pin). This mirrors the F11 intent from `plans/014` and must be ratified (STOP condition if the executor disagrees).

**Implementation**:
- Persist in `NotchHUDConfig` (the established `didSet` + UserDefaults pattern, `NotchHUDConfig.swift:8-10`): `var panelPinned = false` with key `"panelPinned"`, read in `init`.
- `NotchStatusView`: drop `@State isPinned`, read/write `NotchHUDConfig.shared.panelPinned`; `expandTo` no longer clears the pin; add a pure transition.
- New pure state machine in `IslandMetrics`:
  `enum PinCollapseReason { case hoverExit, hotkeyToggle, agentsEmpty, displayReanchor, explicitUnpin }`
  `static func pinAfterCollapse(reason: PinCollapseReason, wasPinned: Bool, persistAcrossCollapse: Bool) -> Bool`
  (returns `wasPinned` for hoverExit/hotkeyToggle/displayReanchor when persistence on; `false` for agentsEmpty and explicitUnpin). `handleAgentsChange` collapses via the agentsEmpty path (pin clears); `handleHover`'s `!isPinned` guard (`:1680,1685`) and `shouldCollapseOnHoverExit` (`IslandMetrics.swift:691-695`) keep working unchanged.
- Relaunch: `panelPinned == true` at launch re-expands only when agents exist (guard `!eventManager.agents.isEmpty`), else stays closed with the pin latched.

**RED tests**:
- **L42 (Logic)**: `pinAfterCollapse` truth table — persists on `.hoverExit`/`.hotkeyToggle`/`.displayReanchor`; clears on `.agentsEmpty`/`.explicitUnpin`; when `persistAcrossCollapse` false (future opt-out) everything clears; config: default false, setter persists (`panelPinned` round-trips like L1/L5 patterns), toggle survives re-init; pin does not resurrect an empty expanded panel (pure gate `pinShouldExpand(hasAgents:)`).

**Failure modes & gaps**: two sources of truth (`@State` vs config) — eliminate by using config only, assert no `@State isPinned` remains; relaunch with pin on and island hidden at startup (`hideAtStartup`) → the pin must not force-show an expanded panel (gate on VisibilityPolicy first); pin + snooze interplay (snoozed island stays hidden, pin latches silently — acceptable, document); accessibility: announce `pin.fill`/`pin` state via `accessibilityValue` (ties to 4b); the `didSet` self-assignment trap seen in `usageBudgetUSD` (`NotchHUDConfig.swift:125-130`) — mirror the clamp-with-guard pattern, don't write defaults from `didSet` during `init` reads.

**Effort**: S. **Swift-only**.

### 1d — Non-destructive Claude hook merging

**Current behavior (verified)**: pure merge/remove in `ClaudeHookInstaller.swift:41-114`; I/O in `SettingsView.installClaudeHook` (`SettingsView.swift:532-567`). L28/L28b cover: foreign `PermissionPrompt` entry survives; re-merge doesn't duplicate; a foreign hook sharing an entry survives. **Adversarial gaps found by reading the code**:

1. **False-positive matcher**: `isBantayHook` is `command.contains("http://127.0.0.1:") && command.contains("/events")` (`:41-45`). A *foreign* command like `myagent --url http://127.0.0.1:8080/events` matches and is **deleted**. No port/tool-shape check.
2. **Corrupt/foreign `hooks` shape**: `mergedSettings` does `(existing["hooks"] as? [String: Any]) ?? [:]` (`:60`) and *overwrites* `merged["hooks"]` (`:69`) — a `hooks` value that is a String/Array is silently replaced, destroying it.
3. **Entry-level shape leak in removal**: `removingBantayHooks` skips non-`[[String:Any]]` hooks values (`:83-87`) so a Bantay command nested in a non-conforming entry survives removal (leak), and `isBantayEntry` (`:48-51`) has the same cast guard.
4. **DATA LOSS on unreadable settings.json (the big one)**: `installClaudeHook` reads with `try?`; on parse failure `settings = [:]` (`SettingsView.swift:535-540`), then uninstall calls `removingBantayHooks(from: [:])` → returns `[:]` → **writes `{}` over the user's `~/.claude/settings.json`** (`:545-554`). Install path likewise writes Bantay-only config, destroying foreign settings. A truncated write, permission hiccup, or foreign JSON5/comment-laden file wipes Claude Code config.
5. **Cross-port re-install**: Bantay installed at port A, `ingestPort` changed to B — re-merge at B removes the old entry (any port matches) then appends, so no duplication (L28b covers same-port); add the cross-port case explicitly.

**Implementation**:
- Tighten `isBantayHook` to the Bantay command *shape*: `curl -s -X POST --data-binary @- http://127.0.0.1:<digits>/events` (prefix-match on `curl` + `--data-binary @-` + localhost port + `/events`). Keep port-agnostic digits so old installs are still removable.
- Harden the pure layer: `mergedSettings`/`removingBantayHooks` return the **input unchanged** when `hooks` exists but is not a `[String: Any]` (never fabricate/replace an unparseable foreign value); treat non-array `hooks` values as opaque and preserve them.
- New pure decider for the I/O layer: `enum ClaudeHookWriteDecision { case write([String: Any]), abort }` with `static func decide(enabled: Bool, fileExists: Bool, parsed: Bool, merged: [String: Any]) -> ClaudeHookWriteDecision` — `abort` whenever `fileExists && !parsed`; `SettingsView.installClaudeHook` calls it and, on `abort`, reverts the toggle + alerts (no write).
- Optional hardening: atomic write (temp file + rename) and a `.bak` copy before first write (mark P3 if time-boxed).

**RED tests**:
- **L44 (Logic)**: (a) `isBantayHook` true for the exact command and a `curl -s -X POST --data-binary @- http://127.0.0.1:9999/events` (old port); false for `myagent --url http://127.0.0.1:8080/events`, `curl http://127.0.0.1/events`, `ssh -R 41817:localhost:41817`; (b) `mergedSettings` with `hooks` = `"broken"` returns input unchanged; `hooks` = `[...]` array unchanged; (c) `removingBantayHooks` with a non-array `hooks` value returns input unchanged; (d) cross-port re-merge: settings with a Bantay entry at port 41000 + foreign entry → merge at 41817 yields exactly one Bantay entry + the foreign entry (no dup); (e) `ClaudeHookWriteDecision.decide` table: `fileExists=false,parsed=false,enabled=true` → write; `fileExists=true,parsed=false` → **abort** regardless of enabled; `parsed=true` → write(merged). Re-assert all existing L28/L28b checks still pass (they must not regress with the tightened matcher — `hookCommand` output matches the shape).

**Failure modes & gaps**: over-tightened matcher misses a legitimately-portable Bantay command variant (e.g. wrapper `sh -c 'curl ...'`) → documented limitation, tested as "survives, unchanged" (never corrupts); Claude Code settings with trailing comments (JSON5) fails `JSONSerialization` → new `abort` path saves us but the hook won't install — surface the alert text, don't silently pass; file exists but is a directory or unreadable (`Data(contentsOf:)` throws → `parsed=false`, `fileExists=true` → abort); concurrent Claude Code process rewriting settings.json mid-write (atomic rename mitigates; note as accepted race, test the decision path not the race); `ingestPort` change between install and uninstall (port-agnostic removal already handles); the `claudeHookInstalled` config flag drift when the file is hand-edited (out of scope, note).

**Effort**: S–M. **Swift-only** (pure layer; `SettingsView` change is a thin adapter to the pure decider).

### 2 — In-app auto-updates (Sparkle) + distribution hardening

**Current state (verified)**: `plans/003-auto-update.md` exists (P2, mechanism-only, feed disabled until first signed release). `scripts/setup.sh --package` already does Dev-ID signing (P12 import, `:72-89`) and notarization (`:90-95`), degrading to ad-hoc (`:105`). `release.yml` attaches `dist/bantay-tui.zip` and opens the cask PR (`:39-82`). Cask has `auto_updates true` (`Cask/bantay-tui.rb:10`). Gap: no Sparkle dep, no feed, no appcast step, and the SwiftPM executable target has no Info.plist (Sparkle reads `SUFeedURL`/`SUPublicEDKey` from the bundle).

**Implementation** (per 003, updated for reality):
- `Package.swift`: add Sparkle package (pin exact version, resolve + record in `Package.resolved`), `.linkerSettings([.linkedFramework("Sparkle")])` on the executable target. **Verify SPM resolution on a CLT-only machine is expected to fail (003 STOP) and that `swift build` still passes without it in CI's Xcode runner** — if linking fails on macOS 13, STOP.
- New `Sources/BantayTUI/SoftwareUpdater.swift` (harness-compiled, so add to both `ci.yml` logic lists): `static let feedURL = "https://github.com/8-BitRhyon/bantay-tui/releases/latest/download/appcast.xml"`; pure `static func normalizedFeedURL(_ base: String) -> String` (trailing-slash vs none — the 003 Step-4 edge); pure `static func shouldAutoCheck(hasSignedRelease: Bool, userEnabled: Bool) -> Bool` (false until first signed release).
- `DynamicIslandApp.swift`: retain `SPUStandardUpdaterController(startingUpdater: true, ...)` (strong ref); menu item "Check for Updates…" before Quit; start auto-check only when `NotchHUDConfig.automaticallyChecksForUpdates` (new facet, default **false**) AND `shouldAutoCheck`. Add facets to `NotchHUDConfig`: `automaticallyChecksForUpdates`, `automaticallyDownloadsUpdates` (003 §Conventions).
- `SettingsView.swift`: "Updates" section (check toggle, download toggle, Check Now button).
- Packaging: `scripts/setup.sh --package` gains Info.plist injection (`SUFeedURL`, `SUPublicEDKey` from env) and — when signing succeeded — `sparkle:generate_appcast dist/ --download-url-prefix <release url>` writing `appcast.xml` + EdDSA signature via `SPARKLE_EDDSA_KEY` secret.
- `release.yml`: add a `sparkle` step (only when the notarize step succeeded) uploading `appcast.xml` as a release asset; keep the existing degraded path untouched (PR #23's fix must not regress the cask PR step).
- Cask: stays `auto_updates true`; no formula change required beyond the release bot's version/sha (already automated).

**RED tests**:
- **L50 (Logic)**: `normalizedFeedURL` (trailing slash in → slash-normalized out; none → appended); `shouldAutoCheck` table (no signed release ⇒ false even if user enabled; signed + enabled ⇒ true; signed + disabled ⇒ false); config facets persist + default off (mirror L1 persistence checks).

**Failure modes & gaps**: Sparkle SPM resolve on CLT-only (`003` §7 already predicts — gate, don't crash); no Info.plist in the `swift build` executable → `SPUStandardUpdaterController` may no-op or throw — must verify the *packaged* `.app` (setup.sh output) carries the keys, and dev builds degrade to menu-item-only; missing `SPARKLE_EDDSA_KEY` → `generate_appcast` fails → skip appcast, keep manual release path (don't block the tag); unsigned release with Sparkle auto-check accidentally enabled → Gatekeeper/notarization mismatch — `shouldAutoCheck` gate prevents it; feed 404 → Sparkle's UI says "up to date" (acceptable); version-parse differences (x.y.z vs v-prefixed) — the tag already strips `v` (`release.yml:54`); `auto_updates true` in the cask claims in-app updates before Sparkle ships — ship 2 before the first tagged release, else flip cask to `auto_updates false` in the same PR.

**Effort**: L. **Needs Xcode**: yes (framework linkage, Sparkle UI, notarization toolchain). Pure feed/decision helpers are harness-testable (Swift).

### 3a — Peek panel overlay (full logs + diff previews)

**Current behavior (verified)**: `captureTail` is fully implemented (`HerdrSocketAdapter.swift:223-247`) and wired to a 6-line inline tail on queue-card hover only (`NotchStatusView.swift:1212-1222`, `fetchPeek :374-391`). No diff preview, no dedicated overlay, no scroll.

**Implementation**:
- Hoist the inline tail cleaner (`:380-384`) into a pure `enum LogFormatter` (new or in `IslandMetrics`): `static func cleanedTail(_ raw: String, maxLines: Int, maxLineLength: Int) -> [String]` (whitespace-trim per line, drop empties, suffix `maxLines`, hard-truncate over-long lines — the 4096-byte adversarial case from 006 Step 4).
- New `Sources/BantayTUI/PeekPanel.swift` (AppKit, not harness): `PeekPanelController` wrapping an `NSPanel` (borrow the `KeyablePanel` pattern, `DynamicIslandApp.swift:21-23`) with a SwiftUI root rendering: full `pane read` tail (≤ 200 lines, scrollable) + a `git diff --stat`/`git diff` preview fetched via a new `HerdrSocketAdapter.captureDiff(cwd:pathLimit:)` built on `ProcessRunner` (1c) — not invented: the diff-stat fetch already proves the git-in-cwd primitive exists; this generalizes it.
- Pure layout seam: `IslandMetrics.peekFrame(anchor islandFrame: CGRect, screenFrame: CGRect, size: CGSize) -> CGRect` — clamps to screen and prefers docking beside the island (reuses the `windowFrame` clamp discipline, `:613-623`).
- Wire: a ▸ affordance on queue cards and roster rows (`approvalQueueCard` :1169-1241, `agentRow` :1461-1632) opens the overlay; Esc/outside-click dismisses; cancel in-flight fetch on dismiss (mirror `endPeek`, `:393-397`); one overlay at a time.

**RED tests**:
- **L45 (Logic)**: `LogFormatter.cleanedTail` — 1000-line input → exactly 6/200 suffix; blank/whitespace-only lines dropped; 100k-char line (the A-corpus size) → truncated to `maxLineLength` without throwing; CJK/emoji preserved; `peekFrame` — docks beside island, clamps inside a 400×300 screen, never overlaps the island, respects scale alignment (reuse `alignedToBackingPixelGrid`).

**Failure modes & gaps**: NSPanel level vs full-screen apps (`window.level` order — match the island's `Int32.max-3`); `pane read` returns binary/ANSI garbage (strip control chars in `cleanedTail` — add a case); agent cwd is a non-repo → diff preview hides (nil), logs still show; 200-line panel on a 768px display overflows — height clamp via `peekFrame`; overlay on a different space after hot-plug (re-anchor on `didChangeScreenParametersNotification`, reusing `handleDisplayChange`); captureTail socket down → CLI fallback slow (runner timeout, 2s); accessibility of the overlay (label + VoiceOver traversal — ties to 4b); multiple rapid open/close cycles (single instance + cancel semantics); memory from huge tails (cap total chars).

**Effort**: M. **Needs Xcode**: yes (NSPanel behavior, Live-audit on a real Mac). Pure tail/frame helpers are harness-testable.

### 3b — Token rate-limit indicators

**Current behavior (verified)**: usage gauge shows tokens + cost + budget fraction (`NotchStatusView.swift:1425-1459`, `UsageTracker.fractionUsed`, `UsageTracker.swift:80+`). No rate (tokens/min) signal.

**Implementation**:
- Pure `UsageParser.rate(lines:now:window:) -> (tokensPerMinute: Double?, lastSeen: Date?)` in `UsageTracker.swift` — transcript JSONL lines carry `timestamp` (verify against real Claude/Codex transcripts before finalizing; where timestamps are absent, return nil and hide the indicator).
- New config facet `usageRateWarnTokensPerMin: Int = 5000` (clamped 100–1_000_000, `didSet` pattern) and render a `· 1.2k/min` segment in the gauge, amber ≥ threshold, red ≥ 2× (mirror the budget fraction coloring `:1428-1437`).
- Aggregate in `AgentEventManager.refreshRosterAndArmWaits` where `usage` is already computed (`:582-585`).

**RED tests**:
- **L46 (Logic)**: `rate` with a 0s window → nil; 60s window with known deltas → expected rate; all-lines-same-timestamp → nil (no division by zero); missing timestamps → nil; clamp + persistence of `usageRateWarnTokensPerMin`; boundary at exactly threshold (warn at ==, red at 2×) — pure `UsageTracker.rateLevel(rate:warn:)` helper so the color decision is tested, not eyeballed.

**Failure modes & gaps**: no transcripts / feature off → nil, indicator hidden (no empty-gauge flicker — gate on `totalTokens > 0` like today); clock skew between lines (negative delta → clamp to 0); DST/midnight rollover (use absolute timestamps, not `minute` math); rate spikes during `pane read` (only poll on poll cadence, `captureInterval`); stale `usage` between polls (keep last value, don't reset to zero); config clamp recursion (same `usageBudgetUSD` pattern, `:125-130`).

**Effort**: S. **Swift-only**.

### 3c — Global keyboard hotkeys (toggle / approve / deny / snooze)

**Current behavior (verified)**: exactly one global hotkey — ⌥Space (keyCode 49), `NSEvent.addGlobalMonitorForEvents(.keyDown)` in `updateGlobalHotkeyMonitor` (`DynamicIslandApp.swift:380-398`), `handleHotkeyToggle` (`:400-408`) shows/hides + posts `.notchHotkeyPressed`. In-island single-key shortcuts already exist (Y/N/digits, `IslandMetrics.shortcutKey` `:509-516`).

**Implementation**:
- Pure mapping: `enum HotkeyAction { case toggleIsland, approveTop, denyTop, snooze15 }` and `IslandMetrics.hotkeyAction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> HotkeyAction?` — table of (keyCode, required modifiers, excluded modifiers). Propose ⌥Space=toggle (unchanged), ⌥Y=approve top, ⌥N=deny top, ⌥S=snooze 15m; each behind a `NotchHUDConfig` facet (`globalHotkeyApproveEnabled`, `globalHotkeyDenyEnabled`, `globalHotkeySnoozeEnabled`, default on for approve/deny, off for snooze to avoid surprises).
- `AppDelegate`: generalize `updateGlobalHotkeyMonitor` to install one monitor per enabled action; dispatch: toggle (existing), approve/deny → `AgentEventManager.performAction(paneId:approve)` for `approvalQueueAgents.first` **guarded by `composingPaneId == nil` and `!isResolving`** (the F2 guard from `plans/014`, `NotchStatusView.swift:319-343`), snooze → `snoozePreset(900)`.
- Permission reality: `addGlobalMonitorForEvents` returns `nil` when Input Monitoring is untrusted on modern macOS — handle nil → log once, leave menu-bar fallbacks working (documented limitation; the app already survives without a11y permission today because ⌥Space also degrades).

**RED tests**:
- **L47 (Logic)**: `hotkeyAction` table exactness (keyCode 49+⌥ → toggle; Y=16, N=45, S=1 — assert the *documented* mapping, not guessed codes); modifier exclusivity (⌥Space+Shift → nil); disabled facets → nil; unknown keyCodes → nil; `handleHotkeyToggle` idempotence on double-press (pure: show→hide→show cycle).
- **L47-X (XCTest, optional)**: NSEvent construction + mapping round-trip.

**Failure modes & gaps**: global monitor nil when untrusted (graceful degrade, log); hotkey conflicts with other apps (opt-in facets, document defaults); approve fires on a pane that just resolved (resolvingPanes guard — reuse `isResolving`); snooze double-fire (snoozePreset already idempotent); keyCode differences across keyboard layouts (⌥Y/N/S are layout-independent *physical* keys — acceptable, document); the island hidden while hotkey fires (approve still routes via manager — by design, an approval must never be dropped); macOS 13 vs 14 keyDown monitor behavior (global monitors predate 14 — fine, but the in-island `.onKeyPress` fallback path stays).

**Effort**: M. **Swift-only** for the mapping; manual test on real hardware for permission behavior.

### 4a — Multi-display: notch-less detection & centered pill

**Current behavior (verified)**: `hasNotch` is inferred from aux-area nil-ness (`DynamicIslandApp.swift:101-103, 194-196`) and `IslandMetrics.notchWidth` requires `safeTop > 0 && auxLeft > 0 && auxRight > 0` else falls back to `notchlessFallbackWidth` (`IslandMetrics.swift:599-605`). `floatingPillFrame` centers below the menu bar (`:271-280`); `topInset` handles `safeTop == 0` (`:607-609`). The risk: macOS 13 vs 14 report `auxiliaryTop*Area` differently on notch-less MacBooks/externals — a non-notched display whose aux areas are non-nil gets treated as notched (wrong geometry), and the reverse. This must be verified on hardware, not guessed.

**Implementation**:
- Pure decision table: `IslandMetrics.hasNotch(safeTop: CGFloat, auxLeft: CGFloat, auxRight: CGFloat) -> Bool` centralizing the heuristic; use it in both `AppDelegate.islandScreen` (`:101-103`) and `islandFrame` (`:194-196`) and `notchWidth` (`:599-605`) so one tested function drives all three.
- `floatingPillFrame`/`windowFrame` already handle the notch-less case; add the "centered status pill" guarantee for `safeAreaInsets.top == 0` externals as explicit tests (midX centering, menu-bar inset, clamp).
- Clamshell/hot-plug already re-anchors via L17 (`DisplayAnchor.needsReanchor`, `:347-359`) — re-assert under the new detector.

**RED tests**:
- **L48 (Logic)**: `hasNotch` table (safeTop 0/24/37 × aux 0/non-zero) with the chosen heuristic documented per row; `floatingPillFrame` centered (`midX == screen.midX`), below menu bar, inside bounds at 400×300 and 5K; `topInset(safeTop: 0, menuBar: 24) == 24`; `notchWidth` fallback `notchlessFallbackWidth` when any input 0; ghost re-anchor L17 still green with the new inputs.

**Failure modes & gaps**: heuristic wrong on one macOS version (STOP — see below, hardware verification required); stage-manager / iPad-in-Clamshell reporting zero aux areas (fallback width engaged — acceptable); external display whose `safeAreaInsets.top` is 0 but menu bar hidden (autohide) → pill rides below a hidden menu bar (accept, document); multi-GPU hot-plug storms (settle delay already `:249-256`); screen coordinate-space mismatches after sleep/wake (re-anchor runs — verify manually).

**Effort**: S–M. **Swift-only** (harness); manual multi-display matrix on macOS 13 + 14.

### 4b — VoiceOver / keyboard navigation / contrast pass

**Current behavior (verified)**: F12 added labels/values broadly (`NotchStatusView.swift:765-767, 877-879, 893-895, 1605-1607`); island is `.focusable()` with `ShortcutKeyPressModifier` (`:266-276`) and the macOS 13 key monitor (`:347-362`); but roster rows are flat `Button`s (no arrow-key navigation), the shelf tab bar buttons (`:1031-1044`) and pin button (`:1152-1163`) have labels but the tab *state* isn't announced, and ~15 text runs still use `.opacity(0.4–0.55)` (`:948, 977, 1150, 1372, 1390-1392, 1529-1554, 1553`).

**Implementation**:
- Keyboard model: pure `IslandMetrics.rowIndex(after current: Int, count: Int) -> Int?` and `rowIndex(before:)` (no wrap; nil at bounds); wire arrow keys in `ShortcutKeyPressModifier`/legacy monitor to move a `@FocusState`-backed `focusedRow`, Enter = primary action (approve for queue cards, expand/peek for rows), Esc = collapse/close peek.
- VoiceOver: `accessibilityValue("pinned"/"unpinned")` on the pin button; `.isSelected` on the active shelf tab; announce expanded/collapsed transitions via `accessibilityAddTraits`/`announcement`; combine peek text into the card's label (`:1221` exists — extend to roster rows).
- Contrast: raise every `.opacity(≤0.55)` text run to ≥0.6 or `.secondary` (HIG-adaptive) per the F12 checklist in `plans/014`; keep deliberate glyphs (spacer dots, overflow `+N`) at 0.45–0.5 and mark them allowed.

**RED tests**:
- **L49 (Logic)**: `rowIndex` navigation table — down from last → nil; up from first → nil; count 0/1 edge; monotonic (no wrap). No harness check for contrast (visual) — add an optional CI grep gate (Layer 1 shell step asserting no `.opacity(0.4`–`0.54`) outside an allowlist) as an explicit, separate workflow change (proposed, not required).

**Failure modes & gaps**: arrow-key capture conflicts with text-field composing rows (`composingPaneId != nil` must swallow arrows — reuse the Escape guard pattern, `:432-445`); VoiceOver double-announcing combined rows (labels + values both set → prefer `children: .combine`); macOS 13 vs 14 `.onKeyPress` availability (legacy monitor path stays); keyboard-only users can't hover (all hover actions must have keyboard twins — peek via Enter/▸); contrast bump regressing the dark-on-black aesthetic (visual, review-gated); the `FocusEffectDisabledCompat` (`:448-457`) hiding focus rings — must keep a visible focus indicator for keyboard users (add a custom focus ring when `reduceMotion`/keyboard nav active).

**Effort**: M. **Swift-only** for the pure model; **needs Xcode/real Mac** for the VoiceOver manual matrix.

## Dependencies & suggested execution order

```
1c (async runner) ──► 1a (diff cache)          ◄─ 3a (peek diff preview reuses runner + 1a's git primitive)
        │
        ├─► 3c (global hotkeys)  ──► 3b (rate indicator, independent)
        │
1d (hook merge)          ──► (independent, Swift-only)
1b (pin persistence)     ──► (independent, Swift-only)
4a (notch detection)     ──► 4b (a11y, last: cross-cuts every new control)
2 (Sparkle + release)    ──► (isolated last: Package.swift churn + signing secrets;
                              keep separate from logic-item PRs so the harness
                              rebuild list and Package.resolved stay reviewable)
```

Order: **1c → 1d → 1a → 1b → 3c → 3b → 4a → 3a → 4b → 2**. Rationale: 1c unblocks 1a/3a/3c; 1d and 1b are small, self-contained, high-trust wins that can land between 1c and the UI work; 4a before 3a (peek overlay needs correct screen anchoring); 2 last because it touches `Package.swift`/`Package.resolved`/workflows and needs secrets that may not exist (degraded path must not block the rest of Phase 1); 4b last because every new control (peek overlay, rate indicator, pin button) must be in the tree before the pass.

## Failure modes & gaps (cross-cutting)

- **Harness compile list drift**: every new source file added to the Logic harness (`ProcessRunner`, `PeekPanel` helpers, `SoftwareUpdater`, `LogFormatter`) must be appended to **both** `ci.yml` `logic` steps (`:57-72`, `:142-157`) or the CI leg breaks while local builds pass. `plans/006` §Scope already pins this ("keep the futures layer live").
- **RED-first discipline**: any item landing without its L41+ block first observed FAIL is a process violation (006, `plans/README.md:11-12`). The final `ALL PASS` count must exceed today's 194; the plan does not ship a regression.
- **macOS version variance**: `.onKeyPress` (14+), Sparkle linkage (13+), aux-area reporting (13 vs 14), Input Monitoring (13 vs 14). Each is gated (`#available`/`if`), never assumed.
- **CLI/daemon missing**: herdr binary absent, socket down, `git` absent, `curl` absent (hook command) — all already degrade to nil/empty/hidden; the new runner adds timeouts so degradation can't hang.
- **Corruption**: hook settings.json, events.jsonl truncated lines, oversized tails, non-UTF8 subprocess output — each has a pure parser + abort path (1d), a truncation cap (3a), and existing tolerant decode paths (`AgentEventManager.poll`).
- **Signing/model failure**: no certs → ad-hoc + documented Gatekeeper bypass (already); notarization failure → release still attaches but is flagged unsigned in notes; Sparkle EdDSA key missing → no appcast, no auto-update — none of these may silently publish a signed-but-unnotarized artifact as an *automatic* update (the `shouldAutoCheck` gate).

## STOP conditions (halt work, report — do not improvise)

1. **Sparkle cannot link/run in the SwiftPM executable target** on macOS 13 (or requires an Info.plist `swift build` won't produce in a way that still passes `swift build -c release`). Halt item 2; ship the rest of Phase 1; report for a packaging-plan amendment (003 §7 predicts SPM/CLT friction — treat *link-time* failure, not CLT resolve, as the blocker).
2. **Notch-detection heuristic cannot be validated on both macOS 13 and 14 hardware** (aux-area reporting differs in practice from the assumption). Do not ship a guessed detector; the `hasNotch` table L48 must be certified against real displays first (4a).
3. **Making the subprocess path non-blocking requires changing the `PlexerAdapter` protocol** (`PlexerAdapter.swift:52-57`) in a way that precommits the tmux/zellij adapters of 017. The protocol is the D2 seam (`plans/015`); a sync→async signature change is a plan amendment, not an implementation detail (1c).
4. **Pin-clear semantics are ambiguous** (clear-on-zero-agents vs keep-pin-through). This is a product decision (mirrors the F1 review-stop in 006 §STOP). If not ratified, implement the *persist-across-user-collapses + clear-on-explicit-unpin* subset only and leave agentsEmpty behavior RED (1b).
5. **Hook write-decision `abort` path conflicts with a real Claude Code config that legitimately uses comments/JSON5.** If a sampled `~/.claude/settings.json` on the owner's machine parses as valid JSON with foreign keys intact but the abort path would still fire, the abort decision needs the owner's call before shipping (1d).
6. **No new /3**: RED and GREEN are separate commits; a work item that lands RED+code in one commit is a process violation and halts that item.
7. **`swift build` or release build emits warnings** after any item — fix or halt; zero-warning is a gate (`plans/015` Gates).

## Effort & toolchain summary

| Item | Effort | Swift-only (Logic harness) | Needs Xcode (XCTest) |
|---|---|---|---|
| 1c Async process runner | M | clamp/variant purity | **yes** (spawn/timeout/deadlock twins) |
| 1a Diff-stat cache | S–M | L41 (key, parse, prune, race) | optional fixture twin |
| 1b Pin persistence | S | L42 | — |
| 1d Hook merge hardening | S–M | L44a–e | — |
| 2 Sparkle + release | L | L50 feed/decision | **yes** (linkage, UI, notarize) |
| 3a Peek overlay | M | L45 tail/frame | **yes** (NSPanel behavior) |
| 3b Rate indicator | S | L46 | — |
| 3c Global hotkeys | M | L47 mapping | manual hardware only |
| 4a Notch detection | S–M | L48 table | manual multi-display matrix |
| 4b A11y pass | M | L49 navigation | **yes** (VoiceOver manual) |

Total: ~2 weeks single-executor, RED-first. Phase 1 completes with `plans/README.md` row 016 DONE, harness ≥230 checks ALL PASS, and the macOS surface ready for Phase 2 (`plans/015` row 77) to start from a stable control plane.
