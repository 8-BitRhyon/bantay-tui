# Plan 013 — The 5 hard engineering challenges

Status: done. Commits (all signed `security-signing@monozen.local`):
- `f2cf701` C1 — approval heartbeat (phantom prompts)
- `1ba43f7` C2 — full-screen & space transitions
- `3166929` C3 — menu-bar collision avoidance
- `c65322a` C4 — display hot-swap & ghost re-anchor
- `829524e` C5 — terminal-agnostic focus
- `b3710c5` fix — beachball hang (pipe deadlock found during C1 prep)

## C1 — Phantom prompts & dropped events
`IslandMetrics.ApprovalHeartbeat` (pure) + `AgentEventManager.heartbeatVerify`:
every roster poll re-verifies pinned approvals against live agent status;
working/done/idle/failed self-clear (phantom kill), unknown keeps pinned
(never phantom-clear). Queue cards gain Force-Focus-Terminal + Retry
(re-poll) fallbacks. L14.

## C2 — Full-screen & multi-space glitches
`FullScreenPolicy` (pure) + `didEnter/didExitFullScreen` observers
(separate tokens) + `activeSpaceDidChange`; both debounce through a
cancellable settle task (0.35s) that re-shows/re-anchors per
`showInFullScreen` (default on). Panel already had
`fullScreenAuxiliary/canJoinAllSpaces/stationary/ignoresCycle` + top-level
window level. L15.

## C3 — Menu-bar collisions (Bartender/Ice)
`MenuBarClearance` (pure): per-side max idle width from
`auxiliaryTopLeft/RightArea` (fallback screen-minus-notch), collision
predicate; `closedPillWidth` clamps the idle strip when
`avoidMenuBarIcons` (default on). L16.

## C4 — Display hot-swap & clamshell ghosts
`DisplayAnchor` (pure): `needsReanchor` for visible windows off every
current screen; `didChangeScreenParameters` + `screensDidWake` route
through debounced `handleDisplayChange` → `reanchorIfGhosted()` +
reposition, with a stderr trace on ghost purge. L17.

## C5 — Terminal-agnostic focus
`TerminalRegistry` (pure, ordered bundle IDs: Ghostty/Warp/WezTerm/
Alacritty/iTerm2/Terminal/VSCode/IntelliJ) + `TerminalFocusser`
(activate resolved app, open Terminal fallback); Force-Focus button +
Settings picker with `preferredTerminalBundleID`. L18.

## Bonus fix
The standalone-scan pipe deadlock that beachballed the app
(`waitUntilExit` before draining stdout) — drain-first + detached tasks.

## Gates (all)
Lint clean, debug+release 0 warnings, harness ALL PASS (L1–L18),
installed + kickstart after each commit, app responsive (0.7–1.2% CPU).