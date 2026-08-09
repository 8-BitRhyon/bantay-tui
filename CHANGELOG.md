# Changelog

All notable changes to this project are documented here. The format is based
on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Live usage, cost & quota** (`KiloUsageAdapter`): reads kilo's SQLite
  ledger (`~/.local/share/kilo/kilo.db` — the source behind `kilo stats`)
  for real daily spend vs. your budget (quota badge + edge-glow) and a
  tokens-per-minute rate via poll-and-diff of cumulative totals. A scalable
  `UsageSample` provider protocol is the base for Codex/Claude/opencode/
  aider adapters. Replaces the dead transcript parser for kilo.
- **Apple Reminders sync** (`RemindersProvider`, EventKit): the task tab
  can sync live Reminders — quick-add, complete, remove, overdue highlight.
- **Barrie-style natural language parser** (`NaturalLanguageParser`): pure
  + deterministic — relative dates (today/tomorrow/in N days/next week/
  EOD/EOM), weekday names, times (at 5pm, 17:00, 9am), priority (!!/!),
  @tags, @agents — with a live parse-preview chip as you type in the task
  bar.
- **herdr push event stream** (`HerdrEventStream`): a persistent
  `events.subscribe` socket subscription replaces the 2-second `agent.list`
  poll as the source of truth for status transitions. `pane.updated` /
  `pane.agent_detected` / `pane.closed` events drive the roster instantly;
  the poll loop is now a slow safety net. Per-pane `herdr agent wait`
  subprocesses were removed (they are redundant with the push stream and
  spawned one `Process` per pane).
- **ntfy.sh push notifications** (`AgentAlertNotifier`): approvals/blocked,
  failures, and completions are pushed to a configured ntfy topic so they
  reach you on other devices. Configurable topic + server (self-hosted
  friendly) in Settings → Push notifications.
- **tmux status-bar integration** (`scripts/bantay-status.sh` +
  `TmuxStatusInstaller`): a one-line agent summary (◐ working · ⚠ blocked ·
  ✓ done) can be wired into tmux `status-right` from Settings.
- **Claude Code `Notification` hook**: installs `agent_needs_input` /
  `agent_completed` / `permission_prompt` / `idle_prompt` matchers — native
  "needs you" and "done" signals that no longer depend on screen detection.
- **Claude Code `PermissionRequest` hook**: the current event name modern
  Claude Code fires (legacy `PermissionPrompt` is kept for older builds).
- **Claude Code `StopFailure` hook**: typed failure reasons
  (rate_limit, auth, billing, …) surface as `failed` events instead of a
  silent stop.
- **Recent activity section** in the expanded roster: last few completions /
  failures (source, what it was doing, how long ago) so you can see what
  happened without opening the peek overlay.
- **Live status in roster rows**: working agents show their current
  `title`/`message` in the status line instead of a generic label.
- **Peek overlay affordance**: replaced the cryptic `▸` with an `eye` icon,
  and gave the overlay an explicit 480×420 frame (it previously collapsed to
  a tiny window).

### Changed

- **Expanded panel declutter** (NotchDrop-style single-list layout):
  - Approval queue cards removed — blocked agents render as roster rows with
    inline approve/deny/choice/submit controls.
  - Footer bar removed (`N agents · done · failed · usage gauge · adapter ·
    pending`) — counts live in the header.
  - Per-row `git diff --shortstat` removed (also dropped the background
    per-agent `git` process).
  - Removed the redundant static header dot and duplicate source chip.
  - Panel height math (`expandedSize`, `contentHeight`, `stableRosterHeight`)
    now accounts for grouped section headers and drops the footer/queue terms;
    the panel is ~78pt shorter for the same roster and fills to the rounded
    bottom with no black band.
- **Corner wings drawn as pure path** (`cornerCutout`): the
  `destinationOut`-blend-in-mask implementation flaked into a stray solid
  square on macOS 26; replaced with a path silhouette verified pixel-identical
  to the blend's output (213 px vs 209 px at 4×, both corners).
- **Black bottom band fix**: removed the redundant inner `.clipped()` after
  `.offset(y:)` in `NotchStatusView.body` — the clip was cutting off the
  footer (drawn at `[topInset…islandHeight]`) against the pre-offset frame
  `[0…contentHeight]`, leaving black pill visible in its place.
- **Drop files onto the notch** (`KeyablePanel: NSDraggingDestination`): the
  island window registers for `.fileURL` drops; dragging a file over the notch
  expands it and opens the Shelf tab, and the drop lands on the shelf.

### Fixed

- Expanded panel scroll bar appeared with grouping enabled because grouped
  section headers (18pt each) were not counted in the roster height math —
  the roster overflowed its scroll area. Headers are now part of the natural
  roster height.
- Peek overlay opened "very small" because the hosting view collapsed to its
  content size; it now has an explicit frame.
- (working tree note) docs: this changelog plus README/ARCHITECTURE refreshed
  to reflect the current implementation.

## [0.1.0] - 2026-08-05 (pre-release baseline)

Historical state before this changelog existed. See `git log` and the plans
under `plans/` for the PR #47–#53 feature set: notch island + idle strip,
expanded control plane with approval queue, universal agent detection (herdr
poll + standalone scan + event-file ingest), global `⌥Space` + roster
shortcuts, approval heartbeat, full-screen/space/menu-bar/display reliability,
cost gauge, shelf, and the Go TUI control client.
