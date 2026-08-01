# Bantay-TUI -- Agent Sentinel Notch HUD

Native SwiftUI macOS app that turns the MacBook notch into an interactive agent-state display, reading lifecycle events directly from Herdr.

## Why
`herdr-focus-notify` (installed) sends native macOS toasts on `agent_status_changed`. This complements it with persistent notch-level visibility: which agent is `blocked`, which just finished (`done`), which needs approval (`access_request`), without opening Notification Center.

## Architecture

| Component | Role |
|---|---|
| `DynamicIslandApp.swift` | Main SwiftUI entry; `.accessory` window hidden when idle, shown at the notch on events; menu bar item (live agent roster, focus actions, Quit) |
| `AgentEventManager.swift` | Dual-source event pipeline: tails `agent-events.jsonl` (launch offset, partial-line buffering, truncation recovery, duplicate suppression, `clear` handling) and polls herdr's live agent list (transition detection, per-source severity, silent re-show of persistent states); publishes `agents` snapshot roster |
| `AgentEventKind.swift` | Enum mapping herdr states to event kinds (`idle` included for the roster) |
| `NotchStatusView.swift` | Notch pill + hover-expandable agent roster; shows on state change, plays per-event sounds (suppressed for silent re-shows), row click focuses the pane |
| `NotchHUDConfig.swift` | `UserDefaults` settings: sounds, volume, auto-clear TTL, sticky approvals, capture interval |
| `HerdrSocketAdapter.swift` | Runs herdr CLI: `herdr agent list` (capture), `herdr pane focus <paneId>` (click-to-focus) |

## Events File vs Socket

Two sources feed the same pipeline:

1. **Direct capture** (default, `captureEnabled`): the manager polls `herdr agent list` every `captureInterval` seconds via the herdr CLI. `blocked → access_request`, `working → progress`, `done → completed`; `idle`/`unknown` are ignored. Per source name, the highest-severity agent wins (`access_request` > `completed`/`failed` > `progress`/`started` > `waiting`); events are emitted only on state transitions, and a persistent `access_request`/`progress` pill silently reappears after TTL expiry while the state holds. No plugin or in-herdr launch required — anything herdr's sidebar knows about appears.
2. **Event file** (optional): `scripts/event-adapter.mjs` (herdr plugin `bantay-tui.integration`, `pane.agent_status_changed`) appends JSONL to `~/Library/Application Support/Bantay-TUI/agent-events.jsonl`, which the manager tails for richer `state_labels` messages.

A direct unix-socket adapter (no CLI subprocess) remains a future option for lower latency; it is not implemented.

## Herdr Event Payload

Herdr invokes the plugin command with the event JSON in `HERDR_PLUGIN_EVENT_JSON`. Verified shape for `pane.agent_status_changed` (from herdr's bundled API schema, protocol 17):

```json
{"event":"pane_agent_status_changed","data":{"type":"pane_agent_status_changed","pane_id":"1-2","workspace_id":"1","agent_status":"blocked","display_agent":"claude","agent":"claude","title":"...","state_labels":{"blocked":"Waiting for approval"}}}
```

`agent_status` is one of `idle`, `working`, `blocked`, `done`, `unknown`. The adapter maps: `blocked → access_request`, `working → progress`, `idle → waiting`, `done → completed`; `state_labels` supplies the pill message.

## Click-to-Focus

Notch click triggers the herdr CLI: `herdr pane focus <pane_id>` (same mechanism as `herdr-focus-notify`). Pane ID comes from the event's `paneId` field.

## Build Requirements

- macOS 14.6+
- SwiftUI, AppKit
- Node.js 18+ for the event adapter (ESM)
- No Electron; native Swift binary
- Open source (MIT license)
- Notarized release via `notarytool` (optional for public download; can distribute as `.dmg` or `.zip` for manual install)

## Installation Path

Manual (for now): build with `swift build`, run `sh scripts/setup.sh` to install the launch agent, and `herdr plugin link <repo>` to register the event hook. Future: Homebrew cask (`brew install --cask bantay-tui`) once notarized.
