# Plan 017 — Phase 2: multiplexer adapters, universal hook SDK, standalone Go TUI

## Status

**Status: proposed** — execution plan for roadmap Phase 2 (see `plans/015-ecosystem-architecture.md`), written 2026-08-04 against `main @ 544a68a`. Not yet executed. RED test IDs (L51+ for the Swift harness, G1+ for the Go module) are assigned below per the SDD rule (`plans/006-test-harness-sdd.md`: RED test first, then implement, then try to break it). Executor: update your row in `plans/README.md` when done.

- **Priority**: P1 (unlocks Phase 3's remote bridge, which rides on the same wire contract)
- **Effort**: L overall (W1 M, W2 S, tmux M, zellij S, process-tracking M, hook SDK L, Go TUI L)
- **Depends on**: 006 (standing rule), 015 (architecture, locked)
- **Category**: multiplexer | integration | cross-platform

## Why

The roadmap's Phase 2 closes three gaps against the product invariant ("control plane for AI coding agents, reachable from anywhere"):

1. **herdr-only control plane.** The `PlexerAdapter` seam exists (`PlexerAdapter.swift:49-65`) but only `HerdrSocketAdapter` conforms; `NotchStatusView.swift:39` and `AgentEventManager.swift:147` hardcode it. tmux and zellij users get no pane list, no focus, no capture tail. The detection logic already knows about them (`PlexerAdapter.swift:36-41`); the adapters don't exist.
2. **Event sourcing is herdr/Claude-shaped only.** Events flow in via the herdr plugin (`scripts/event-adapter.mjs`, `HerdrPluginInstaller.swift`), the Claude Code hook (`ClaudeHookInstaller.swift`), and the optional HTTP ingest (`EventIngestServer.swift`). Aider, Windsurf, Cursor, Codex, and *any custom script* have no first-class, documented way to emit status events — yet the standalone process scan already names them (`AgentDetector.swift:39-69`).
3. **The macOS notch is the only surface.** Per D1 a standalone terminal UI is a Go binary; per D2 it interoperates only through the wire contract + task-spec JSON. Nothing like it exists yet, and the repo has no Go at all.

Phase 2 also lands the two shared artifacts Phase 3 needs: a **versioned, testable wire contract** (the gateway protocol below) and the **first concrete task-spec JSON schema**.

## Wire contract additions (W1–W4)

The existing NDJSON framing is the seam. All additions keep the request/response shape from `HerdrSocketClient.swift:8-12` (`{"id","method","params"}`) and the response shape from `HerdrSocketClient.swift:25-46` (`result` string OR `error {code,message}`). Unknown fields are ignored, unknown methods rejected — the gateway enforces that server-side.

### W1 — Control gateway over a Unix domain socket (Swift server; Go client)

New listener in the Swift app, sibling to `EventIngestServer` (same `NWConnection`/`NWListener` approach as `EventIngestServer.swift:72-83` but with `NWEndpoint.unix`). One connection, one request line, one response line, then close (same pattern as `HerdrSocketClient.perform`, `HerdrSocketClient.swift:121-162`).

- **Socket path**: `~/Library/Application Support/Bantay-TUI/control.sock`; env override `BANTAY_CONTROL_SOCKET` (resolution mirrors `HERDR_SOCKET_PATH` at `HerdrSocketClient.swift:56-61`).
- **Request** (one NDJSON line): `{"id":"req_ab12","method":"agent.list","params":{}}`
- **Response success** (one NDJSON line): `{"id":"req_ab12","result":{"kind":"tmux","agents":[...]},"error":null}`
- **Response error**: `{"id":"req_ab12","result":null,"error":{"code":"unknown_method","message":"bantay.frobnicate"}}`
- **Method catalog** (owned by Bantay, routed to the active `PlexerAdapter`; shapes mirror the herdr verbs the adapter already speaks):

  | Method | Params | Result | Routes to |
  |---|---|---|---|
  | `bantay.ping` | `{}` | `{"type":"pong","v":1,"kind":"herdr\|tmux\|zellij\|none"}` | detection (`PlexerAdapter.swift:21-44`) |
  | `agent.list` | `{}` | `{"kind":"...","agents":[AgentInfo...]}` — `AgentInfo` = `HerdrAgentInfo` shape extended with optional `"pane_tty"`, `"pane_pid"` | `listPanes`/`listAgents` |
  | `pane.read` | `{"pane_id":"...","lines":6}` | `{"text":"..."}` | `captureTail` |
  | `pane.send_keys` | `{"pane_id":"...","keys":["y","enter"]}` | `{"ok":true}` | `sendKeys`/`approve`/`deny` |
  | `pane.focus` | `{"pane_id":"..."}` | `{"ok":true}` | `focusPane` |
  | `agent.prompt` | `{"pane_id":"...","text":"..."}` | `{"ok":true}`; `text` may carry a W3 task-spec JSON | `sendLine`/`agentPrompt` |

- **Error codes**: `unknown_method`, `invalid_params`, `pane_not_found`, `transport`.

### W2 — UDS event-ingest extension (Swift server; any script/tool emits)

*Assessment:* **extend, don't replace.** Keep the localhost HTTP listener for the SSH `-R` tunnel path (`EventIngestServer.swift:72-83`), and add a parallel UDS listener at `~/Library/Application Support/Bantay-TUI/ingest.sock` (env override `BANTAY_INGEST_SOCKET`). Both funnel into the same validator + `ingestEventLine` (`AgentEventManager.swift:804-830`).

The UDS listener accepts **two** payload forms on one connection:

1. **HTTP POST over UDS** — reuse `IngestHTTP.request` unchanged, enabling `curl --unix-socket <path> -X POST --data-binary @- http://localhost/events`.
2. **Bare NDJSON event line** — if `IngestHTTP.request(from:)` returns nil (no `\r\n\r\n` / `Content-Length`), treat the buffer as one event line and validate it with the `AgentEventPayload` decoder. This is the "any CLI tool/script" path: write one JSON line, close.

Event line schema (identical to the events-file payload; `v` optional, unknown fields ignored):

```json
{"v":1,"source":"aider","type":"access_request","title":"run tests","message":"Aider needs approval","paneId":null,"workspaceId":null,"variance":"yes_no","choices":null}
```

### W3 — Task-spec JSON (shared Swift + Go; first concrete schema)

015 names `Goal`/`Files`/`Constraints` but nothing implements it. This plan fixes the first schema, versioned, emitted by both runtimes and consumed by herdr/agents via the existing `agent.prompt` transport:

```json
{"v":1,"goal":"Add --dry-run flag to bantay","files":["Sources/BantayTUI/PlexerAdapter.swift"],"constraints":["no new dependencies","macOS 13 floor"],"source":"bantay-macos"}
```

- Swift: pure `TaskSpec: Codable` + a rule-based `AgentPromptComposer` (deterministic, no LLM) wired into `submitPrompt` at `NotchStatusView.swift:1781` — composed JSON goes in the `text` param; plain-text prompts stay supported.
- Go: mirrored struct in `tui/internal/taskspec`. Round-trip tested in both languages.

### W4 — Universal hook SDK surface (Swift + shell; per-tool adapters)

The universal surface is **W2's UDS ingest** plus a generic emitter script and per-tool installers that mirror the `ClaudeHookInstaller` pattern (settings merge preserving foreign keys; removal that never touches foreign hooks; payload mapping).

- `scripts/hook-emit.sh`: `hook-emit --source aider --type access_request --title "..." [--pane-id ...] [--workspace-id ...] [--variance yes_no|choices|multi] [--choices a,b]` → writes one W2 line to the UDS socket; falls back to appending the events file directly.
- New Swift `HookSdk.swift`: `hookCommand(for tool:)`, `mergedSettings(existing:tool:)`, `removingHooks(from:tool:)`, `mapToEventPayload(_:tool:)` — one row per tool:
  - **Aider**: hook config file + event names **verified at implementation time** against the installed `aider --help`/docs.
  - **OpenAI Codex CLI**: `~/.codex/config.toml` hooks section (event names verified at implementation).
  - **Windsurf / Cursor**: no stable hook surface documented — rely on the existing standalone scan + transcript tailing (`AgentDetector.swift:19-36`) and expose W2 for their custom scripts. No installer is shipped for tools without a verified hook mechanism.

## Work items

### WI-1 — tmux adapter (Swift)

- **Approach**: `TmuxAdapter.swift` conforming to `PlexerAdapter`, mirroring `HerdrSocketAdapter`'s structure: executable discovery (PATH + `$TMUX` env), CLI fallback verbs, fire-and-forget from a detached task. Pane listing: `tmux list-panes -a -F '#{session_name}\t#{window_index}\t#{pane_index}\t#{pane_id}\t#{pane_tty}\t#{pane_pid}\t#{pane_current_command}\t#{pane_current_path}'` with a `-F` variant fallback for older tmux, never auto-starting a server. Focus: `select-pane -t <session:window.pane>` + `switch-client -t <session>` then activate the terminal app via `TerminalFocusser.focus`. Approve/deny/choices: `send-keys -t <target> y Enter`. Capture: `capture-pane -t <target> -S -<N>`.
- **Wire contract**: contributes `PaneInfo.tty/pid/session*` fields to W1's `agent.list` result; no new methods.
- **Swift vs Go**: Swift only (macOS app).
- **RED tests (harness)**: L51 block — `-F` line parsing (two template shapes + tab/quoted variants), id composition `%N` → `session:window.pane`, tty/pid/current-command extraction, detection additions, empty output → `[]`, malformed line → skipped, `PaneInfo` decodes with/without new fields.
- **Effort**: M.

### WI-2 — zellij adapter (Swift)

- **Approach**: `ZellijAdapter.swift`, same conformance. `zellij ls` for sessions; pane listing + `dump-screen` for capture tail; `zellij action` verbs for focus/send-keys — **exact verb spellings verified against the installed binary** (zellij 0.40+ reorganized `zellij action`). Zellij pane identity is `(session_id, pane_id)` — composed into the single `paneId` string the protocol already uses.
- **RED tests (harness)**: L52 block — verb construction, `zellij ls` output parsing (text + JSON variants), `(session,pane)` id composition/drift on session kill, unhandled command → empty results.
- **Effort**: S.

### WI-3 — Process-level pane tracking & focus routing (Swift)

- **Approach**: a pure `PaneFocusRouter` that maps a `paneId` to (a) the multiplexer command that selects the pane (tmux `select-pane`+`switch-client`, zellij focus verb, herdr `agent.focus`) and (b) the macOS terminal to activate (`TerminalRegistry`, `TerminalFocusser.swift:9-31`). The tty→terminal-window mapping is terminal-specific and only partially scriptable — **first slice** = activate the terminal app + select the pane inside the mux (guaranteed), per-window targeting documented best-effort. Pane-id drift: re-key by `tty`/`pid` before giving up.
- **RED tests (harness)**: L53 block — pid/tty→pane resolver, drift fallback, focus routing table per mux kind, standalone (no mux) → `TerminalFocusser` only, pid-reuse guard, no-terminal fallback.
- **Effort**: M.

### WI-4 — Control gateway (W1; Swift server)

- **Approach**: `ControlGatewayServer.swift` — UDS `NWListener`, one-request-per-connection, route table `method → (PlexerAdapter verb, param decoder)`. Active adapter resolved by detection extended to return a chosen kind; `NotchStatusView.swift:39` and `AgentEventManager.swift:147` switch to a shared `AdapterProvider`. Unknown method → `unknown_method`; malformed params → `invalid_params`; stale socket file → detect, unlink, rebind.
- **RED tests (harness)**: L54 block — framing round-trip, `unknown_method`/`invalid_params` rejection, path resolution, route table completeness, `bantay.ping` version + kind.
- **Effort**: M.

### WI-5 — UDS event-ingest (W2; Swift server)

- **Approach**: extend `EventIngestServer` with a second listener on `NWEndpoint.unix`; reuse `IngestHTTP` for form (1), bare-line fallback for form (2). Config: new `ingestSocketEnabled` facet (default ON — a local socket owned by the current user is not a network exposure, unlike the TCP port which stays default-off).
- **RED tests (harness)**: L55 block — HTTP-over-UDS parses, bare-line fallback accepts a valid payload / rejects non-JSON / oversized (>64 KiB), path resolution, stale-socket handling.
- **Effort**: S.

### WI-6 — Universal hook SDK (W4; Swift + shell)

- **Approach**: `HookSdk.swift` + `scripts/hook-emit.sh` + per-tool installer entries. Aider/Codex get verified installers; Windsurf/Cursor get a transcript root added to `AgentDetector.swift:19-36` and a documented W2 emit recipe. `hook-emit.sh` must be `bash -n` clean and tested with a stub socket path.
- **RED tests (harness)**: L56 block — hook-emit arg parsing (missing `--type` → exit 2), per-tool mapping from canned payloads, merge keeps foreign keys, removal drops only Bantay hooks, idempotent double-install, never fabricates a hook for a tool marked unverifiable.
- **Effort**: L.

### WI-7 — Standalone Go TUI (Go/bubbletea; first slice)

Per D1 this is **Go**, and per D2 it interoperates only through the wire contract.

**Module layout** (new `tui/` directory at repo root; the Swift package is untouched):

```
tui/
  go.mod                        # module github.com/8-BitRhyon/bantay-tui/tui; toolchain go1.22.x
  cmd/bantay-tui/main.go        # flags (--socket, --events-file, --retry), bubbletea Program
  internal/wire/wire.go         # NDJSON framing: requestLine/parseResponseLine/extractLines
  internal/wire/wire_test.go    # G1 (RED first)
  internal/taskspec/taskspec.go # TaskSpec struct + JSON round-trip (W3)
  internal/taskspec/taskspec_test.go   # G2
  internal/events/events.go     # AgentEventPayload mirror + status→kind map
  internal/events/events_test.go       # G3
  internal/gateway/client.go    # control-gateway UDS client: call(method, params)
  internal/gateway/client_test.go      # G4 (in-process mock UDS listener)
  internal/ui/model.go          # bubbletea model: status list + approve/deny + connect/retry
  internal/ui/model_test.go     # G5 (model update pure-function tests)
  README.md
```

**First-slice scope**:
- **Connect/retry**: dial `BANTAY_CONTROL_SOCKET` or the W1 default; health probe = `bantay.ping`; exponential backoff 500ms→8s cap; explicit `connecting / connected / error: <msg>` view state; never spin on a dead socket.
- **Status list**: poll `agent.list` (2s working cadence, 10s idle); render source · status · title · project·branch.
- **Approve/deny**: on blocked rows, `pane.send_keys` `["y","enter"]` / `["n","enter"]`. Choices/multi deferred.
- **Ctrl-C semantics**: Esc/Ctrl-C quits only outside a text input; approve keys never exit.

**Reuse**: `internal/wire` is a line-for-line port of `HerdrSocketProtocol`; `internal/gateway` a port of `call`/`perform` pointed at the gateway socket; `internal/taskspec` mirrors the Swift `TaskSpec`. **Gateway-first, herdr-direct fallback**: if the gateway socket is absent, the client dials herdr's socket with the same framing.

**RED tests (Go)**: G1 framing round-trip (garbage lines, missing id, error shape); G2 task-spec round-trip + unknown-field tolerance; G3 status mapping incl. unknown status → idle; G4 mock-UDS-server request/response + timeout; G5 model transitions (connect → error → retry, approve marks pane resolving).

- **Effort**: L. **Toolchain**: Go ≥ 1.22 (not installed on this machine today — the first Go step gates on a `go version` check).

## RED test matrix (SDD)

| ID | File | Asserts |
|---|---|---|
| L51 | `.kilo/LogicCheck.swift` | tmux parsing/detection/PaneInfo (WI-1) |
| L52 | `.kilo/LogicCheck.swift` | zellij verbs/listing/id drift (WI-2) |
| L53 | `.kilo/LogicCheck.swift` | pane-focus router, drift, tty/pid re-key (WI-3) |
| L54 | `.kilo/LogicCheck.swift` | gateway framing, routing, unknown-method, paths (WI-4) |
| L55 | `.kilo/LogicCheck.swift` | UDS ingest both forms, validation, stale socket (WI-5) |
| L56 | `.kilo/LogicCheck.swift` | hook SDK merge/remove/map + hook-emit args (WI-6) |
| G1–G5 | `tui/internal/**/*_test.go` | Go TUI wire/taskspec/events/gateway/model (WI-7) |

New Swift source files must be appended to the `swiftc` logic-harness line in `.github/workflows/ci.yml` (logic job). Go tests run via a new CI job (Layer 3.6: `gofmt -l` empty, `go vet` clean, `go test ./...`).

## Failure modes & gaps (per item)

- **WI-1 tmux**: `-F` template fields differ across versions; `list-panes -a` fails when no server exists (never auto-start); `pane_pid` is the *shell* pid, not the agent — approve keys still hit the right pane, but pid-based tracking needs the descendant walk; socket perms can deny a sandboxed app; `$TMUX` set but socket stale → commands fail → fall back to detection nil; pane ids `%N` regenerate on server restart. Mitigation: dual-format parsing + variant fallback (the exact pattern of `paneListCommandVariants`, `HerdrSocketAdapter.swift:144-149`).
- **WI-2 zellij**: `zellij action` verbs changed across versions (unknown verbs return exit ≠ 0); pane ids are session-scoped and die with the session; `dump-screen` can emit control sequences; zellij headless/SSH has no client to attach. Mitigation: verb discovery + tests pinned to what the installed binary accepts.
- **WI-3 process tracking**: per-terminal window targeting is not uniformly scriptable (iTerm2 yes, Terminal partial, Warp/Ghostty none); PID reuse guarded by tty match; OSC 7/9 not emitted by all shells; no terminal running → `openSystemTerminal` fallback.
- **WI-4 gateway**: stale socket file from a crash → detect + unlink + rebind; concurrent clients — one request per connection avoids cross-talk, but writes must be serialized; slow clients block the listener queue → per-connection timeout; adversarial input: method names with control chars → reject, params of wrong JSON type → `invalid_params`, oversized lines (>64 KiB) → close.
- **WI-5 UDS ingest**: scripts failing *silently* (exit 0 on unhandled events, indistinguishable from "no event"); AF_UNIX path length (~104 bytes) — validate at bind; NUL/garbage bytes → reject; a writer that never closes → receive timeout; socket owned by current user only, never world-writable.
- **WI-6 hook SDK**: tool hook configs drift across versions (verified-at-implementation contract); tools without hooks must fall back to scan+tailing, never a fabricated hook; double-firing (Claude hook + herdr plugin + scan all emitting for one agent) — dedupe by `identityKey` already exists (`AgentEventManager.swift:287`), throttle emit cadence; hook scripts exit 0 without emitting → heartbeat already kills phantom prompts.
- **WI-7 Go TUI over slow links**: NDJSON partial reads must re-buffer (port of `extractLines`); long-RTT sockets need per-call timeouts and non-blocking backoff; terminal resize churn must not reset state; ANSI/wide-unicode titles must render safely; Ctrl-C is shared between the agent's pane and the TUI — only Esc/Ctrl-C outside input quits; reconnect storms → capped backoff.

## Dependencies, execution order, STOP conditions

**Order** (each item's RED block lands first):

1. **WI-4 Control gateway (W1)** — the shared contract. *(RED L54)*
2. **WI-1 tmux adapter** → **WI-3 process tracking**.
3. **WI-2 zellij adapter** (independent; small).
4. **WI-5 UDS ingest (W2)** *(RED L55)*.
5. **WI-6 hook SDK (W4)** *(RED L56)* — depends on 4.
6. **WI-7 Go TUI** — depends on 1 (gateway) and W3; can start in parallel once 1 is green.

**STOP conditions**:
- WI-4: if the gateway's one-request-per-connection model conflicts with `AgentEventManager`'s MainActor pipeline, stop and review before adding background concurrency to the manager.
- WI-1: if a tested tmux version's `-F` output cannot be parsed unambiguously with the dual-format fallback, stop and pin the minimum supported tmux version rather than guessing.
- WI-3: if per-terminal window targeting is attempted before the app-activation + pane-select slice is shipped, stop — per-window scripting is explicitly deferred.
- WI-7: if bubbletea's input model cannot distinguish Ctrl-C-for-quit from agent keys after the first prototype, stop and document the key contract before shipping the approve/deny slice.
- Any harness regression: revert, report, do not improvise.

## Effort & toolchain

| Item | Effort | Toolchain |
|---|---|---|
| WI-4 gateway (W1) | M | Xcode/CommandLineTools, Swift 6.0, Network.framework |
| WI-1 tmux adapter | M | Swift (CLI plumbing; no AppKit) |
| WI-2 zellij adapter | S | Swift |
| WI-3 process tracking | M | Swift + AppKit (`TerminalFocusser.swift`) |
| WI-5 UDS ingest | S | Swift |
| WI-6 hook SDK | L | Swift + shell (`hook-emit.sh`, `bash -n`) |
| WI-7 Go TUI | L | Go ≥ 1.22 (not installed today — gate on `go version`), bubbletea v1 |

App stays macOS 13 floor; voice is untouched (Phase 3, D3). Go land is additive (`tui/` only) — the gateway is the only Go-reachable surface in the app.

## Gates

- Harness `ALL PASS` — L51–L56 RED-first blocks; `.kilo/LogicCheck.swift` compile line (ci.yml `logic` job) updated with every new source file.
- `swift format lint --recursive --strict Sources Tests` — clean; `swift build` debug + release — 0 warnings.
- Go: `gofmt -l` empty, `go vet` clean, `go test ./...` green (new CI job).
- `scripts/hook-emit.sh` passes `bash -n` + a stub-socket dry run.
- Manual smoke: island roster + approve/deny under tmux, then zellij, then herdr; TUI connect/retry against a stopped/started gateway.

## Done criteria

- [ ] tmux and zellij adapters conform to `PlexerAdapter`; island roster/focus/capture works under all three muxes; detection picks the right one (L51/L52 green)
- [ ] Selecting an agent in the island focuses the terminal + pane (L53 green); per-window targeting documented as best-effort
- [ ] Control gateway UDS serves W1's catalog with `unknown_method`/`invalid_params` rejection (L54 green)
- [ ] UDS ingest accepts both HTTP-over-UDS and bare NDJSON lines into the watched events pipeline (L55 green)
- [ ] `hook-emit.sh` + per-tool mappings ship; unverifiable tools documented as scan+tailing-only (L56 green)
- [ ] Go TUI first slice (status list + approve/deny + connect/retry) builds, `go test ./...` green (G1–G5), `bantay-tui` connects to the gateway and survives gateway restarts
- [ ] Task-spec JSON (W3) round-trips identically in Swift and Go; compose flow emits it via `agent.prompt`
- [ ] No gate regressions; `plans/README.md` row added for 017

## Out of scope (Phase 3)

SSH bridge, remote devbox, web/mobile companion, iOS/Android voice, subscribe/push on the gateway (TUI polls in the first slice), choices/multi in the TUI, `bantayd`-style daemon split (forbidden, 015).
