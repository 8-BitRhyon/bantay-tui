# Plan 022: Antigravity Full Integration (CLI, IDE, Metrics, Readable Messages)

## Objective

Make Antigravity a first-class Bantay citizen, on par with OpenCode and Claude Code:
live status, sessions with real token and cost numbers, provider-reported quota,
and notch headlines a human can read. Today Antigravity is detected but not
measured, and its notch text is often raw transcript noise.

---

## Current state (verified 2026-10-30)

- **Detection exists.** `AgentDetector.swift` maps `agy`, `antigravity`, and
  `antigravity-ide` processes to the `antigravity` source, and scans
  `~/.gemini/antigravity-ide/brain`, `~/.gemini/sessions`, and `~/.gemini` as
  transcript roots. The IDE is focusable (`com.google.antigravity-ide`) and the
  strip auto-chain classifies its windows.
- **Events are thin.** `HookSdk.swift` maps Antigravity hook payloads to
  canonical events, but `mergeHooks` is a no-op for Antigravity: there is no
  verified hook install path, no IDE event adapter, and no approval channel.
  Status comes from the standalone `ps` scan plus transcript tails only.
- **Metrics are absent.** `UsageTracker.swift` and
  `UniversalQuotaAdapters.swift` contain no Antigravity code. Sessions can be
  recorded from generic completion events, but with no token or cost
  attribution. There is no Antigravity row in the Quotas view.
- **Quota is recognized but unsourced.** `QuotaAxiTracker.swift` inserts
  `antigravity` into the recognized set when `~/.gemini` exists, then has no
  case that emits a row for it. Per the quota honesty rule, that is correct
  behavior until a provider-reported source exists.
- **Messages are hit-or-miss.** `summarizeToolCall` covers a few Antigravity
  tool names (`run_command`, `view_file`, `replace_file_content`). The rest
  fall through to a humanized tool name or raw text. Conversation data lives
  in `~/.gemini/antigravity-ide/conversations/<uuid>.db` (SQLite: `steps`,
  `gen_metadata`, `trajectory_meta`) with protobuf blobs, plus `.pb` files.
  Nothing decodes those, so step-level activity (browser subagent, planning,
  tool calls) cannot be rendered faithfully.
- **Local facts.** Antigravity IDE.app is installed. There is no `agy` binary
  on PATH. `~/.gemini/antigravity-ide` holds `brain/`, `conversations/`,
  `code_tracker/`, `context_state/`, and logs.

---

## Spike findings (2026-10-31, this machine)

- **S1 done.** Conversations decode cleanly. `steps` carries `step_type`,
  `status`, and a protobuf `metadata` blob whose top-level fields 30 and 31
  hold the tool action and its human summary (for example "Listing apps in
  /Applications"). Observed step types: 15 is the planner or model turn
  (91 of 188 steps in one conversation), 21 is tool execution (46), the
  rest are rarer kinds (101, 132, 31, 33, 8, 7, 14, 9, 23, 98, 99).
  `gen_metadata` holds the system prompt and checkpoint content. No token
  usage fields were found in steps or gen_metadata, so per-session tokens
  stay unrecorded rather than estimated.
- **S2 done.** A provider quota source exists locally: the IDE caches a
  `userStatus` protobuf under `antigravityUnifiedStateSync.userStatus` in
  its `state.vscdb`, plus credit sentinel flags in `modelCredits`.
  `AntigravityQuota.swift` decodes the payload field 33.1.15 per-model
  `remainingFraction` (float 0...1) and `resetTime` (epoch seconds), and
  field 36.2 for the plan tier. The Quotas view shows the lowest fraction
  across models with that same model's reset, beside the measured row.
  A cached window whose reset is already past renders as STALE and never
  drives routing. Credit counts and the weekly window remain undecoded
  because their field mapping is not proven. The blob contains the account
  email and is never logged, returned, or committed.
- **S3 done.** The CLI is installed and running: `~/.gemini/bin/agy`
  (version 1.4.12, hub mode on local ports). `agy models` lists the
  account models (Gemini 4 Argon tiers, Gemini 3.8 Flash tiers, Claude
  Opus and Sonnet 5.5 tiers, GPT-OSS). There is also a separate CLI data
  root at `~/.gemini/antigravity` (`conversations/`, `brain/`,
  `conversation_summaries.db`), distinct from the IDE store; which of the
  two a given session lands in depends on how it was started.

## Landed so far (2026-10-31)

- `AntigravityStore.swift`: read-only SQLite reader over the IDE
  conversation store, with a minimal protobuf string reader for the
  summary fields. Working state comes from file mtime (the IDE writes
  steps as the agent acts).
- Roster: standalone detection now takes its Antigravity activity and
  working flag from the store headline instead of transcript tails.
- Sessions: finished conversations (quiet ten minutes, at least three
  steps) are recorded once, with honest zero tokens.
- Quota: a measured Antigravity row (steps and conversations) appears in
  the Quotas view, home-scoped like every other probe.
- Quota decode: `AntigravityQuota.swift` reads the cached provider
  percentage and reset time, opens SQLite read-only without `immutable=1`
  so the WAL is visible, and labels an expired window STALE. The reported
  and measured rows share one Antigravity group with distinct ids.
- CLI root: `AntigravityStore` now reads both
  `~/.gemini/antigravity-ide/conversations` and
  `~/.gemini/antigravity/conversations`, dedupes by conversation ID, and
  uses the WAL mtime as the working heartbeat. Agents launched through the
  IDE hub no longer read as idle.
- Per-agent registry: `AntigravitySummaryStore` reads the CLI hub's
  `conversation_summaries.db`. The table carries the same active fields the
  webview uses (`not_fully_idle`, `parent_conversation_id`, `agent_name`,
  `nesting_depth`, `workspace_uris`). Bantay now emits one row per active
  conversation instead of one row per source.
- Messages: the scanner headline is the step summary; the tool vocabulary
  in `summarizeToolCall` covers find, code search, URL reading, image
  generation, browser, and planning steps.

## Gaps to close

1. No usage numbers: tokens, cost, and model per Antigravity session.
2. Credit count and weekly window: the per-model quota fraction is
   decoded, but AI credit amounts and the weekly window are not mapped
   with confidence.
3. No structured activity: protobuf steps are unread, so headlines degrade
   to filenames, plan text, or binary noise.
4. No decision channel: approvals inside the IDE are observe-only, and the
   UI does not say so distinctly for this source.
5. CLI parity is unproven: no `agy` on this machine, so the CLI surface
   (flags, transcripts, hooks) is unverified.

---

## Phase 0: Spikes (time-boxed, before any feature code)

### S1. Decode the conversation store
- Read one real `conversations/<uuid>.db`: enumerate `steps.step_type` and
  `status` values, and decode one `step_payload` and one `gen_metadata` blob.
- Deliverable: a field map (step kind, tool name, model, token fields if any)
  recorded in this plan or a research note. Kill criterion: if payloads are
  encrypted or undocumented protobuf with no stable schema after one day,
  fall back to `brain/*.md` artifacts plus IDE storage (S3) and descope
  per-step rendering.

### S2. Find the quota source
- Candidates, in order: the IDE's own storage
  (`~/Library/Application Support/Antigravity*`), `context_state/`,
  `code_tracker/`, the jetski OAuth token with the Gemini quota endpoints,
  and `agy` CLI output if the CLI can be installed.
- Deliverable: one provider-reported quota signal with reset time, or a
  written finding that none exists. No estimated percentages: if there is
  no provider number, the Quotas view shows measured spend only, labeled
  as measured, never a fabricated remaining percent.

### S3. Verify the CLI surface
- Install or locate `agy`; record version, transcript location, and whether
  it accepts hooks or a status line. If the CLI cannot run here, scope CLI
  work to detection parity and mark IDE as the primary target.

---

## Phase 1: Detection and events (CLI + IDE)

- Promote Antigravity in the standalone scanner: stable per-window pane IDs
  for the IDE (same pattern as L141 multi-session discovery), working and
  blocked states from conversation DB mtimes plus step status, not only
  transcript text tails.
- Add an Antigravity event adapter that watches the conversations DB
  (WAL-aware, read-only) and emits canonical events: started, progress,
  completed, failed. Blocked or approval steps emit `waiting` with the
  step summary as the title, never `access_request` until Phase 5 proves a
  decision channel.
- If S3 finds a hook or status-line surface, wire it through `HookSdk`
  (replace the no-op merge) with an installer in Settings next to the
  Claude and OpenCode integrations.
- Acceptance: with the IDE running a task, the roster shows the window
  within one scan interval, state changes land without a pane, and a
  finished task records exactly one completion.

## Phase 2: Sessions and usage metrics

- Parse conversation DBs into session rows: start and end time, model,
  step count, status, and token usage where S1 found it. Attribute tokens
  to the `antigravity` source in `UsageTracker` (lifetime accrual plus
  per-session deltas, same metering rules as other sources: no baseless
  lifetime totals as deltas).
- Cost: price by model with the existing rate table; unknown models show
  tokens with cost 0 and an honest label, never an invented price.
- Acceptance: one real IDE session appears in Sessions with duration,
  model, and token count matching a hand-checked DB query; Spend today
  includes it under `antigravity`.

## Phase 3: Quota

- Implement `AntigravityUsageAdapter` in `UniversalQuotaAdapters.swift`
  from the S2 source: remaining percent, reset time, tier. Wire it into
  `QuotaAxiTracker.probeLiveQuotas` under the existing `antigravity` case
  (rename of the recognized key, with `agy` and `gemini` aliases kept).
- If S2 finds no provider quota: ship measured-spend only (tokens and cost
  today, limit state unknown) and document the gap in the Quotas empty
  state for this provider.
- Acceptance: the Quotas view shows an Antigravity row whose numbers match
  the IDE or API at probe time; a temp-home probe stays empty (same
  home-scoping rule as the OpenCode fix).

## Phase 4: Readable messages

- Build the Antigravity tool vocabulary from S1's field map: map step
  types and tool names (search, file view and edit, command, browser,
  planning, image, MCP) to the existing humanized headline style in
  `AgentDetector.summarizeToolCall` and `AgentPresentation`. Unknown tools
  keep the current humanized fallback.
- Add fixtures from real (sanitized) Antigravity tails and DB step rows to
  `RedesignPhase1Tests` and the logic harness: each fixture asserts the
  exact headline the notch will show. Binary or protobuf fragments must
  clean to an empty headline (suppressed), never render raw.
- Acceptance: ten real Antigravity activity samples produce ten readable
  headlines, zero raw JSON, zero binary noise, zero bare filenames where a
  verb exists.

## Phase 5: Decisions (only with a real channel)

- If the IDE or CLI exposes an approval hook (S3), route decisions through
  it and mark the source actionable. Until then, Antigravity cards are
  observe-only with the existing "open its terminal" wording, and task
  dispatch keeps using focus plus input synthesis with its current
  accessibility gates.
- Acceptance: either an approval answered from the notch is confirmed by
  the IDE, or the UI demonstrably never offers a decision it cannot send.

---

## Sequencing and cost

- Phase 0 gates everything: roughly one day. Phases 1 and 4 can proceed
  from S1 alone. Phase 2 follows S1. Phase 3 waits on S2 and must not be
  faked. Phase 5 is optional and last.
- Every phase lands with tests first (fixtures from real local data,
  sanitized), the logic harness green, and the full suite green.

## Risks

- Protobuf schema drift across IDE versions: pin parsing to observed
  fields, tolerate unknown step types, and version-gate nothing.
- The IDE database is live (WAL): open read-only, never write, and treat
  a locked or missing DB as "no data", not an error state.
- Two installed IDE bundles (`Antigravity IDE.app` and a versioned copy):
  detection must not double-count windows or sessions.
