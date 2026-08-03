# Plan 009 — Execute approvals inline from the island

Status: done (commit `d237b7e`, signed `security-signing@monozen.local`).

## Goal
The approval queue was yes/no-only; numbered choices and multi-select
prompts still forced a trip to the terminal. Now the full approval surface —
yes/no, single-choice, multi-select — is executable from the notch UI.

## What changed
- `IslandMetrics.ApprovalControls` (pure, internal): variance defaulting
  (nil → yes/no, empty choices → yes/no), numbered 1-based option labels,
  multi-select toggle set (`toggling`), sorted submit numbers
  (`selectionNumbers`), submit label.
- `AgentSnapshot`: carries `variance`/`choices` + `approval` computed model.
- `AgentEventManager`:
  - `pendingApprovals` map (per pane) fed by `showEvent` for
    accessRequest/waiting events, cleared on other kinds.
  - `mergeApprovals(into:)` attaches the decoded prompt to blocked roster
    rows; idle/non-blocked agents never carry approval data.
- `NotchStatusView`: queue cards render full controls — yes/no approve+deny,
  numbered one-click choices (`approveChoice`), multi-select toggles +
  Submit (`approveMulti`, per-agent `queueSelections` state).

## Gates
- `swift format lint --recursive --strict Sources Tests` — clean.
- `swift build` + `swift build -c release` — 0 warnings.
- Harness — RED-first L7 (controls semantics, snapshot build, merge attach,
  idle exclusion), `ALL PASS`.
- Installed + `launchctl kickstart -k` — island visible, no crash.

## Next
- Peek (captureTail) panel per queue card.
- tmux/zellij adapters behind `PlexerAdapter`.