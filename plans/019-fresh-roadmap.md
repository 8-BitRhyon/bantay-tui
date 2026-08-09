# Plan 019 — Fresh roadmap (independent audit, 2026-08-06)

Written against commit `1b6bb22` + the in-flight working tree (push stream,
ntfy, tmux installer, declutter) as of 2026-08-06. Two independent read-only
audits (codebase health + product direction) plus manual vetting informed
this plan. This is a **roadmap**, not a single build spec — each item is
scoped so it can become its own implementation plan (020+, in order below).

## Why

`DEVELOPMENT_PLAN.md` and `plans/README.md` no longer match the tree:
M2 (multiplexer adapters) and M3 (deeper control plane) are shipped; plan 018
is a 4-track aspirational mega-project for a project with zero tagged
releases and zero users; and the in-flight branch will fail CI today because
the harness/CI compile lists omit `HerdrEventStream.swift` and
`AgentAlertNotifier.swift`. Before any feature work, the baseline must be
true again.

## Ground truth (verified, with evidence)

1. **CI is red on the working tree.** `.github/workflows/ci.yml` compile
   lists (`:57–78`, `:148–169`) omit `HerdrEventStream.swift` and
   `AgentAlertNotifier.swift`; recompiling the harness against the working
   tree yields 6 errors. `swift build` is green.
2. **The harness has 881 checks, not 990.** `rg -o "check\(" | wc -l` = 881.
   `plans/README.md:64` still says 194. The changelog's "990 PASS" and the
   README's "L1–L64" are also wrong (highest label is L58).
3. **The usage pipeline is fully dead.** `usage`/`usageRate` are `@Published`
   and recomputed every poll (including transcript enumeration,
   `AgentEventManager.swift:645–668`), but zero UI reads them (grep of
   `NotchStatusView` = 0 hits). Config `showUsageGauge`/`usageBudgetUSD`/
   `usageRateWarnTokensPerMin`, the Settings section, and
   `UsageTracker.fractionUsed`/`rateLevel` are dead. The dir-mtime memo
   (`UsageTracker.transcriptMtime`, reads directory mtime) is also wrong for
   appends — usage would be permanently stale even if re-rendered.
4. **`captureInterval` (Settings "Poll interval", default 2.0) is wired to
   nothing.** The capture loop sleeps on `idlePollInterval` (default 10.0),
   which has no Settings UI. The user-facing control does nothing.
5. **tmux/zellij adapters are built and tested but never instantiated.**
   `TmuxAdapter()`/`ZellijAdapter()` appear nowhere; the runtime hardcodes
   `HerdrSocketAdapter` in `AgentEventManager.swift:161`,
   `NotchStatusView.swift:42`, `DynamicIslandApp.swift:633`. Plan 017's
   `AdapterProvider` seam was never built.
6. **`HerdrEventStream` subscribes dot-spelled, parses underscore-spelled.**
   Subscriptions use `pane.updated`; `parseLine` switches on `pane_updated`.
   If herdr echoes the subscription type, the stream silently no-ops — zero
   tests cover the wire parse.
7. **Other confirmed corpses:** `spawnAgentWait`, `DiffStatCache`/
   `DiffStatCacheKey`/`parseShortstat`/`prune`, `queueSplit`/
   `queueCardHeight`/`expandedQueueCap`/`footerHeight`, `mergeStandalone`,
   `pollHerdrAgents`, `attachPane`, `_ = livePanes`, Settings toggles for
   `expandedShowQueue`/`expandedQueueCap`, test seams shipped in production
   (`recordStartForTesting`/`publishEventForTesting`), the
   `ingest.token` file that `scripts/hook-emit.sh` reads but nothing writes.
8. **`ProjectContext` reads `.git/HEAD` on the main actor per agent per poll**
   (`AgentEventManager.swift:68–79`), despite a comment claiming otherwise.
9. **`lastStreamStatus`/`lastStreamTitle` grow unbounded** (never pruned on
   `paneClosed`).
10. **herdr-absent probe loop:** `HerdrEventStream.start()` re-probes ~1s
    forever when the socket file is missing.

## Positioning (owner's north star)

This app serves **one person first** — not a large user base. It must be the
daily-driver surface you trust to never miss an approval and to show what
agents are doing, so you don't keep unlocking the Mac to check. The phone
is a first-class surface, not an afterthought: **mobile-first is a flagship
priority**, because the whole point is to not be at the laptop.

The strategy: (1) make the Mac app genuinely **usable and reliable** by
copying what BoringNotch / NotchDrop / DynamicNotchKit already do well
(their polish is proven — borrow their code and patterns for the components
they nail: notch shape + animations, hover-reveal, shelf drop UX,
notifications), then (2) build the mobile surface that turns "check the
Mac" into "check the phone," and only then (3) invest in the things that
**differentiate from Claude Code's chat itself** — the cross-agent timeline,
cost guardrails, and ambient multi-agent awareness that the chat can never
give you.

## Roadmap

### Phase 0 — Make the baseline true (DONE 2026-08-06)

All of Phase 0 shipped in one session:

- **0.1 — CI is dependable.** The hand-maintained harness compile list (the
  exact thing that made the push-stream branch go red) is gone. One script,
  `scripts/build-logic-harness.sh`, globs every `Sources/BantayTUI/*.swift`
  except the four UI-only files (DynamicIslandApp, NotchStatusView, PeekPanel,
  SettingsView), and is what **both** CI logic jobs and the SDD gate run. New
  pure-logic files are picked up automatically — the harness list can never
  drift again. `ci.yml` + `.kilo/command/sdd.md` reference the script; doc
  check counts corrected (881, L58).
- **0.2 — Wire fixtures.** L59 pins the push-stream wire contract
  (`HerdrStreamPane.fromJSON`: pane_id/agent/agent_status/cwd/workspace_id/
  title/focused + fallbacks); L60 pins ntfy payloads. Both RED→GREEN.
- **0.3 — Stopped the runtime waste.** Transcript token/cost enumeration
  (per-poll disk I/O for data nothing renders) is now gated behind
  `usageTrackingEnabled` (default off; Settings toggle renamed honestly;
  Phase C turns it back on when spend history lands). `captureInterval` — the
  setting with a UI control — is now the loop cadence (was silently ignored
  in favor of the orphaned `idlePollInterval`, which was deleted). The purely
  cosmetic corpses (spawnAgentWait, DiffStatCache, mergeStandalone,
  pollHerdrAgents, attachPane, queue params, test seams) are deferred to a
  dedicated cleanup PR — they're inert and harness-tested, so deleting them
  now is churn that risks breakage with zero runtime benefit.
- **0.4 — Reliability.** `lastStreamStatus`/`lastStreamTitle` prune on
  `paneClosed`; the herdr-absent 1s probe loop now backs off (0.5s→4s cap)
  instead of spinning forever.

Phase 0 is the whole point: **nothing broken ever lands.** The gate is now
mechanical — CI runs format → build → tests → harness-script → release →
secrets, and the harness list cannot drift.

### Phase A — Make the Mac app genuinely good (this week; copy the competitors' polish)

The bar: **the notch app must be as good as BoringNotch/NotchDrop at the
things they nail**, so it stops feeling like a buggy experiment and starts
feeling like a product. Borrow their open-source components (MIT): DynamicNotchKit
shape/animation, NotchDrop shelf + drop UX + notification patterns, Pow
effects. Reimplement cleanly — don't copy GPL code (BoringNotch is GPL-3.0;
use it as reference, lift the MIT-origin pieces like `NotchShape`).

| # | Item | What | Why | Effort | Depends on |
|---|------|------|-----|--------|------------|
| A1 | **First tagged release (v0.2.0) + cask sha256** | Tag, build release zip, fill `Cask/bantay-tui.rb` sha256/url, document Gatekeeper bypass | Nothing downstream (install, phone bridge, Sparkle) works without a URL; one-day event | 1 d | 0 |
| A2 | **Polish pass: animations + hover-reveal + notch shape** | Adopt DynamicNotchKit's corner morph + spring animations, hover-reveal actions (BoringNotch `HoverButton` pattern), verify the corner-cutout path against the mask on macOS 26 | The single biggest "not reliable / not good" feeling is the UI; competitors already do this beautifully — borrow it | 1–2 d | — |
| A3 | **Shelf as a first-class surface** | NotchDrop's drop-on-notch + drag-out-back + QuickLook previews + Pow drop feedback, wired to the existing shelf | Competitors' shelf is their marquee feature; ours is bare — copy the proven UX | 1–2 d | — |
| A4 | **Notifications that act** | `NotchNotification` popovers for blocked/done, Notification Center approval actions (approve/deny buttons on the notification itself) | "Never miss an approval" starts with the notification being useful, not just visible | 1 d | — |
| A5 | **Menu-bar roster mirror + 1-click approve** | Live roster submenu (approve/deny inline) for notch-less displays / hidden island; `⌥Y`/`⌥N` global approve/deny | Approval latency from any surface; menu already rebuilt per `menuNeedsUpdate` | 1 d | — |
| A6 | **openCode structured adapter** | opencode hook config + `HookSdk` mapping → `access_request`/`progress`/`completed` into the existing pipeline | Today opencode is scan-only — agents you actually use must be first-class | 1–2 d | 0 |

### Phase B — Mobile-first parity (the flagship; next week)

The phone surface replicates what the Mac app already does — same roster, same
actions, same "what happened" — so **you don't unlock the Mac to see/act.**
"Mobile parity" means: the phone is not a degraded remote view; it is the same
instrument panel, sized for a lock screen.

| # | Item | What | Why | Effort | Depends on |
|---|------|------|-----|--------|------------|
| B1 | **ntfy approve-back + rich status body** | ntfy action buttons (approve/deny/choice/view) POST back to the Mac over the existing SSH-reverse-tunnel / Tailscale path; the notification body carries per-agent status lines | Fastest path to phone approval — no app store, works today, is the "not worth unlocking the Mac" proof; mirrors the Mac's inline controls | 1–2 d | A1, A4 |
| B2 | **Mobile-first web companion (PWA)** | Serve the roster + timeline + approvals from the Go bridge as a mobile-first progressive web app (installable, push-capable) — the full phone UI | One codebase serves phone + any browser; no App Store gate; the mobile-first design target that "replicates what the Mac does" | 3–5 d | A1 |
| B3 | **Approve from lock screen (iOS Live Activity / APNs)** | Native iOS notification surface with approve/deny actions (no app open) | The zero-friction demo moment: approve from the lock screen | 2–4 d | B2 or B1 demand |
| B4 | **"While you were away" digest (mobile-first)** | On open: N approvals answered, M completed, $X spent, slowest/fastest agent | Completions currently poof in 3s; the phone digest is the "what happened" answer | 1 d | C1 timeline, C2 spend |

### Phase C — Differentiation from Claude Code's chat (the reason to exist)

Once the Mac is reliable and the phone mirrors it, spend on what **Claude
Code's own chat can never show you** — the cross-agent, cross-session ambient
layer that only an always-on instrument panel can own.

| # | Item | Why | Effort | Depends on |
|---|------|-----|--------|------------|
| C1 | **Multi-agent timeline** | Render the event stream Bantay already captures as per-agent activity strips (working bursts, approvals, completions) + combined view — no competitor surface does *multi-agent* timelines | 3–5 d | — |
| C2 | **Spend history + budget guardrails** | Persist daily token/cost snapshots; Spend view (day/week); ntfy + edge-glow alert on threshold; projected run-rate | Cost visibility *with alerts* is a HUD-only advantage; re-enables `usageTrackingEnabled` (Phase 0 gated it) | 2–3 d | 0 |
| C3 | **MCP server** | Expose roster + approval verbs over MCP (stdio/SSE) on top of `ControlGateway`'s NDJSON method catalog | Agents can query/control each other — the demo "my agents ask the watchdog"; the gateway is already a method server | M | — |
| C4 | **Session resume** | Per-row "Resume": focus terminal + re-attach session (`tmux attach` / herdr focus / `zellij attach`) | Fixes the "how do I continue what it was doing" pain | S–M | A1 |
| C5 | **Project/workspace view** | Group roster by project with per-project cost + status | Turns 5 agents into 2 projects at a glance; scales the timeline | M | C1 |

### Cut / defer with prejudice

- **Plan 018 as written** (bridge+relay+Noise E2E, iOS *and* Android
  companions, PromptCompiler ×3, voice). The *mobile-first* need is served by
  B1/B2/B3 instead — cheaper, no relay to host. Take only the single-devbox
  remote bridge slice (C6 candidate) and the read-only web dashboard (that's
  B2's backend) from 018. Keep the 018 WI-2 feasibility matrix doc (S).
- **015 D3 voice** (FluidAudio/Parakeet, 735 MB model, macOS 14 floor). Delete
  from the active roadmap.
- **W3 task-spec JSON / PromptCompiler** — no consumer until MCP (C3) exists.
- **Sparkle auto-update** — defer until there's a release + real usage; not
  what makes the app *usable*.
- **Go TUI multi-select/choices** — keep parked; the island + phone are the
  approval surfaces.
- **Per-window pane targeting** (017 WI-3 second slice) — long tail across 5
  terminals with unstable APIs; the app-activation slice ships the value.
- **New hook installers for Windsurf/Cursor** — keep scan+tailing; only
  opencode (A6) earns a real installer.

## Success signals (grade the roadmap against these, not phase completion)

This serves **you** first — so the honest KPIs are personal:

1. **"I never miss an approval and I don't unlock the Mac to check."** Time
   from approval-push to action (target: median <30s from the phone after B1);
   stale-approval incidents ≈ 0 (every nonzero is a bug, not a feature
   request).
2. **It's your daily driver.** The app is genuinely usable — you use it every
   workday, it survives a day of agents without a beachball or a missed event,
   and you reach for the phone rather than the laptop to see what's happening.
3. **It's demonstrably better than Claude Code's own chat.** The things the
   chat can't show you — the cross-agent timeline, spend guardrails, ambient
   multi-agent awareness — are the features you actually rely on.
4. **Demo-to-adoption conversion** (secondary): install → agents visible
   within 60s; the phone-approve screen-share is trivial to reproduce.

## Execution notes

- Follow `plans/006` discipline: every item opens RED (failing harness/test
  first) and closes with the full gate set including the harness `ALL PASS`.
- Phase 0 is DONE (2026-08-06) — CI is mechanical and dependable. The SDD
  gate is now: `bash scripts/build-logic-harness.sh` + `swift format lint` +
  `swift build` zero-warnings + `swift build -c release`. Nothing lands
  without all four green.
- **Cadence is days, not months:** A (this week) → B (next week) → C (the
  week after, re-evaluated against the success signals). Each item is sized
  for a focused day or two.
- **Borrow, don't reinvent:** for A2–A4, read BoringNotch / NotchDrop /
  DynamicNotchKit source (in the repo or `git clone` them) and lift the
  MIT-origin components (DynamicNotchKit's `NotchShape`, NotchDrop's drop
  + shelf + notification patterns, Pow effects). BoringNotch is GPL-3.0 —
  reference only, reimplement the patterns; never copy its file wholesale.
- The wire fixture for the push stream already pins the `pane_updated`
  spelling the live socket emits (verified 2026-08-06; harness L59).
- Order: A1 → A2–A5 (make it good) → B1–B4 (make it mobile — the phone
  mirrors the Mac) → C1–C5 (make it different from the chat).
