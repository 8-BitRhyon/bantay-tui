# Plan 018 — Phase 3: remote devbox bridge, cross-platform overlays, web & mobile companion

Status: **proposed**. Read-only planning output; transcribed verbatim. No code in this plan. Executor plans (016/017) land before this one runs.

## Status header

- **Priority**: P2 (all three work items; the remote bridge is the dependency backbone)
- **Effort**: L overall — WI-1 (L), WI-2 (S, document-only), WI-3 (L ×3 tracks)
- **Risk**: HIGH — new runtimes (Go, Kotlin), a live security boundary (pairing/E2E), mobile OS backgrounding, and a second build track (Android) share only the wire contract
- **Depends on**: 006 (RED discipline — standing rule), 015 (architecture — locked), 016/017 (macOS completion, multiplexer/local ecosystem) where their `PlexerAdapter` surface is the local approval path the bridge reuses
- **Category**: remote | cross-platform | mobile | voice-adjacent (PromptCompiler)
- **Planned at**: 2026-08-04, working tree `544a68a` + plans 015–017

## Why

The product invariant in 015 is that Bantay is a **control plane for AI coding agents, reachable from anywhere**. Today the island is strictly local: it watches `agent-events.jsonl` (`AgentEventManager.swift:151-156`, `:244-277`), polls `agent.list` over the local socket or CLI (`HerdrSocketAdapter.swift:166-184`), and approves by injecting keystrokes into local panes (`HerdrSocketAdapter.swift:99-119`). The only remote path is the manual `ssh -R <port>:localhost:<port>` hook tunnel into the localhost-only ingest listener (`EventIngestServer.swift:58-76`) — one-way, unauthenticated-by-design (localhost trust), fire-and-forget, and it cannot carry *approvals back to the devbox*.

Phase 3 closes the loop: agents run where the work is (devbox/VM/Docker), the approval authority stays on the Mac, and the user can review/approve from a phone or browser. D1 locks the runtime split: Swift owns Apple UI, Go owns every cross-platform surface. D2 locks the seam: the wire contract is the only interop surface. D3 locks voice as rule-based, no-LLM. D5 locks source-first distribution.

## Done criteria

- [ ] **WI-1**: `bantay-bridge` Go binary ships (devbox side) + `bantay-relay` (thin, token-blind) + macOS pairing UI. Remote telemetry streams into the same pipeline as local events (`AgentEventManager.ingestEventLine`, `AgentEventManager.swift:804-830`), and remote approval commands reach a herdr pane on the devbox with **at-most-once applied** semantics (verified via `cmd_id` dedup, never double-fires).
- [ ] **WI-2**: Feasibility matrix for Linux (GNOME Shell extension / Hyprland topbar) and Windows (Taskbar Flyout / Windows App SDK) committed; explicitly NOT a build plan; recommendation + STOP/GO gates for a future 019.
- [ ] **WI-3**: Pairing of one iOS and one Android device each; ActivityKit Live Activity approval card renders and approves; Android foreground service keeps the tunnel alive across screen-off; both apps offline-queue approvals and flush on reconnect with dedup; a read-only web dashboard renders live telemetry; PromptCompiler emits task-spec JSON (Goal/Files/Constraints) on both runtimes with no LLM call.
- [ ] Harness `ALL PASS` (`.kilo/LogicCheck.swift`), new L-blocks RED-first; `gofmt -l` empty, `go vet` clean, `go test ./...` green; Swift gates stay green.

## Grounding — what exists today

| Capability | Where | Limitation for phase 3 |
|---|---|---|
| NDJSON request/response framing | `HerdrSocketProtocol`, `HerdrSocketClient.swift:6-62` | Local UNIX socket only, one request per connection, no push |
| Event payload shape | `AgentEventPayload`, `AgentEventManager.swift:852-861` | No sender identity, no sequence number, no timestamp field |
| Localhost HTTP ingest | `EventIngestServer.swift:58-124` | One-way (devbox→Mac), unauthenticated localhost trust, no ack, no dedup |
| Ingest config | `NotchHUDConfig.swift:131-139`, Settings UI, wiring `DynamicIslandApp.swift:445-465` | Default OFF (secure) |
| Approval action verbs | `HerdrSocketAdapter.approve/deny/approveChoice/approveMulti`, `:99-119` | Local only |
| Double-fire protection | `resolvingPanes` + `performAction`, `AgentEventManager.swift:135-144`, `:724-758`; `ApprovalHeartbeat`, `IslandMetrics.swift:384-411` | Local only |
| Event kinds / variance | `AgentEventKind.swift:3-70` | Shared vocabulary to reuse verbatim over the wire |
| Multiplexer abstraction | `PlexerAdapter` protocol, `PlexerAdapter.swift:49-65` | The bridge should speak PlexerAdapter verbs, not herdr-specific CLIs |
| RED harness | `.kilo/LogicCheck.swift`, L11 ingest block | New blocks RED-first; adversarial ids stable |

## Wire contract v2 — the seam extensions (D2)

D2's rule: versioned, unknown fields ignored, unknown methods rejected. v2 keeps that invariant and adds an **envelope** so the local payload stays byte-compatible.

### Envelope (one NDJSON line, both directions)

```json
{
  "v": 2,
  "kind": "telemetry" | "command" | "ack" | "pairing" | "hello" | "ping",
  "devbox_id": "db_01HXAB3…",
  "seq": 412,
  "ts": 1722823200000,
  "payload": { }
}
```

- `v` — wire version. Unknown major → connection refused; unknown fields → ignored.
- `seq` — **per-sender, per-session** monotonic 64-bit counter. Not wall-clock. Basis for replay protection and outbox ordering.
- `ts` — epoch ms, sender clock; **display-only**, never trusted for replay/ordering.
- `payload` — for `telemetry`, the existing `AgentEventPayload` fields plus optional `devbox`/`workspace` display names. The Mac-side decoder must decode-or-drop (never crash) exactly like `ingestEventLine`.

### Telemetry streaming (devbox → Mac)

```json
{ "v": 2, "kind": "telemetry", "devbox_id": "db_…", "seq": 413,
  "ts": 1722823201000,
  "payload": { "source": "kilo", "type": "access_request", "title": "Run `npm test`?",
               "pane_id": "w3:p3", "workspace_id": "w3",
               "variance": "yes-no", "choices": null } }
```

Mapping to local events is unchanged: the bridge re-emits herdr `agent.list` statuses / Claude hook payloads exactly as `ClaudeHookInstaller.mapToEventPayload` does today (`ClaudeHookInstaller.swift:118-152`).

### Approval commands + ack (Mac → devbox)

```json
{ "v": 2, "kind": "command", "devbox_id": "db_…", "seq": 7,
  "cmd_id": "cmd_9f2c…", "op": "approve" | "deny" | "choice" | "multi" | "stop" | "prompt",
  "pane_id": "w3:p3",
  "approval_id": "db_…:w3:p3:413",
  "option_numbers": [1, 3] }
```

```json
{ "v": 2, "kind": "ack", "devbox_id": "db_…", "seq": 414,
  "cmd_id": "cmd_9f2c…",
  "accepted": true,
  "result": "delivered" | "applied" | "dropped_stale",
  "error": null }
```

- `cmd_id` — client-generated UUID; **the idempotency key**.
- `approval_id` — stable identity of the prompt being answered (`devbox_id:pane_id:telemetry_seq`), so a stale approval referencing an already-resolved prompt is dropped (`dropped_stale`) using the same live-status logic as `ApprovalHeartbeat.shouldKeepPinned` (`IslandMetrics.swift:384-399`).
- `op:choice` sends 1-based index + Enter; `op:multi` sends comma-joined indices + Enter — mirroring `HerdrSocketAdapter.swift:110-119`.

### Pairing (bootstrap, one-time)

```json
{ "kind": "pairing", "op": "begin",  "pairing_id": "pr_…", "code": "123456", "expires_at": 1722823200000 }
{ "kind": "pairing", "op": "confirm", "pairing_id": "pr_…", "code": "123456",
  "device_pub": "<x25519-public-key-b64>", "device_info": { "platform": "ios"|"android"|"go", "name": "iPhone" } }
{ "kind": "pairing", "op": "accepted", "mac_pub": "<x25519-public-key-b64>",
  "device_token": "<256-bit-random-b64>", "session": { "expires_at": … } }
```

### Framing rules (both runtimes, tested in RED)

- One JSON object per line, `\n`-terminated, max line 64 KiB.
- Unknown `kind`/`op` → ack `{accepted:false, error:"unknown_method"}`.
- `hello` handshake: `{v, kind:"hello", devbox_id, capabilities:[…]}` — sent first after connect; version negotiation happens here.

## WI-1 — Remote devbox & SSH bridge (Go, per D1)

**Effort: L. Toolchain: Go 1.22+ (x/crypto/curve25519, an audited Noise impl), plus the existing herdr CLI. No Swift changes to the macOS core path.**

### Implementation approach

1. **Go module** `bridge/` in a new repo directory (Package.swift stays Swift-only; Go is a separate module by D1).
2. `bantay-bridge devbox` — runs on the devbox/VM/Docker container. Talks to local herdr exactly like `HerdrSocketAdapter` does (socket-first `agent.list`, CLI fallback), re-emits status changes as `telemetry` lines, and applies `command` ops by sending keys through herdr `agent send-keys` / the socket methods.
3. **Transport** — outbound WSS to the relay (devbox almost never has an inbound port; this flips the current `ssh -R` model to outbound from the devbox, which is the common case for Codespaces/cloud VMs).
4. `bantay-bridge relay` — thin token-blind relay (Go, single binary): terminates TLS, forwards ciphertext frames between paired peers, holds no long-term keys. Optional direct P2P upgrade via pion/webrtc data channel later.
5. macOS side: a small Swift client inside the app (Network.framework + URLSessionWebSocket) connects *outbound* to the relay, runs the Noise handshake, and feeds decrypted lines into `AgentEventManager.ingestEventLine` — no daemon, D1's single-process invariant holds.

### Security model

- **E2E choice: Noise Protocol, `Noise_XX_25519_ChaChaPoly`** (X25519 static keys, ChaCha20-Poly1305, SHA256). Rationale vs WebRTC DTLS: this channel is low-rate structured JSON, not media; Noise gives authenticated key agreement + per-message AEAD without SDP/ICE state machines, and keeps the **relay ciphertext-only**. WebRTC DTLS stays reserved for the mesh path where ICE/TURN NAT traversal earns its weight. If a future P2P hop is added, the Noise-derived session key is reused as the pre-shared secret for the DTLS handshake — one identity domain.
- **Pairing handshake**: 6-digit code as the pre-shared bootstrap → XX handshake over the relay → both sides exchange long-term static keys → derive bidirectional symmetric keys with independent counters.
- **Replay protection**: per-direction 64-bit sequence numbers authenticated inside each AEAD frame; IPsec-style sliding window. `seq` in the JSON envelope is the *application-level* copy for ordering/dedup; the AEAD counter is the *crypto-level* replay guard.
- **Token lifecycle**: `pairing_code` (6 digits, one-time, TTL 10 min, max 5 attempts) → `device_token` (256-bit random, long-lived, revocable) → `session_token` (256-bit random, 24 h, refreshed on reconnect, bound to `device_token`). Relay sees routing ids and ciphertext only; **relay compromise leaks nothing beyond metadata**.
- **Approval authority stays on the Mac**: the devbox never self-approves; a `command` is honored only when authenticated under the paired session and the referenced `approval_id`'s pane still reports blocked (mirror of `ApprovalHeartbeat`).

### Offline queue (devbox side)

- `~/.config/bantay/outbox.jsonl` — `telemetry` lines buffered when the relay is unreachable. Append-only, atomic rename on flush checkpoint.
- `~/.config/bantay/delivered.jsonl` — `cmd_id`s already `applied`. On reconnect: the Mac re-sends `command` only for `ack.result != "applied"` or missing ack, and the devbox **drops any `command` whose `cmd_id` is already in `delivered.jsonl`** — at-most-once applied, at-least-once delivered with dedup.

### RED test strategy (Go, plus L-block mirror in LogicCheck)

- Go unit tests (RED first): envelope parse/version reject; unknown-kind ack; `cmd_id` dedup table (same id twice → one `applied`); `approval_id` stale-drop against synthetic pane states; outbox ordering + flush checkpoint; AEAD sliding-window replay rejection; Noise handshake against fixed known-answer vectors (RFC-conformant test vectors from the Noise spec), not just self-roundtrip.
- LogicCheck L-blocks (pure Swift mirrors, **L61** envelope validation, **L62** `approval_id` builder/parser `devbox:pane:seq`, **L63** ack-state machine pending → applied / dropped_stale → never re-send).
- Adversarial additions: 100k-char titles (size cap), out-of-order `seq`, duplicated `cmd_id` storm, `variance`/`choices` mismatch.

### Failure modes & gaps

- **NAT traversal failure**: outbound WSS relay is the primary path — no inbound hole needed. Direct P2P is an optimization, never a dependency.
- **Relay unreachable**: outbox queues telemetry; approvals stay queued on the Mac outbox with an explicit "delayed" badge; no silent drop.
- **Devbox with no outbound access at all**: unsupported by the WSS model. Gap acknowledged: document the legacy `ssh -R` ingest path as the fallback for this topology, read-only.
- **Tampered telemetry**: AEAD fails → frame dropped + session error counter; never parsed.
- **Token leakage in logs**: loggers redact codes/tokens/keys; CI grep-test asserts no `code`/`token`/`priv` fields ever print.
- **Lost approvals**: `cmd_id` + ack + re-send only when unacked; UI shows "pending" until `applied`.

## WI-2 — Cross-platform overlays (feasibility matrix ONLY)

**Effort: S (document). Toolchain: none required (research + optional spike on a VM).**

An **explore phase**: produce a matrix and a recommendation; no build plan, no code. D1 governs: Go owns the surface logic — the Go binary is the daemon/relay client, the overlay is a thin view over it.

| Criterion | GNOME Shell extension | Hyprland topbar | Windows Taskbar Flyout | Windows App SDK (WinUI 3) |
|---|---|---|---|---|
| View runtime | GJS/ESM (JS) | waybar custom module / hyprland IPC | WinUI 3 flyout (C#/XAML) | WinUI 3 (C#) |
| Bridge interface | D-Bus to Go user service | unix socket / waybar `custom/exec` | Named pipe to Go service | Named pipe to Go service |
| Telemetry push | D-Bus signals | poll or socket stream | pipe stream | pipe stream |
| Approval actions | D-Bus method call → Go | exec/pipe back to Go | pipe write | pipe write |
| Packaging | extensions.gnome.org (zip) | config + binary | MSIX/side-load (signing) | MSIX (signing) |
| E2E crypto | n/a — loopback to Go daemon | n/a | n/a | n/a |
| Maint. burden | MED (GNOME version churn) | LOW (hyprland IPC stable-ish) | HIGH (WinUI 3 churn) | HIGH |
| Dev cost | MED | LOW | HIGH | HIGH |
| Best-fit | Primary Linux surface | Secondary/lightweight | Primary Windows surface | Rejected for v1 |

**Recommendation**: Linux = **GNOME Shell extension + D-Bus to a Go user service**, with a **Hyprland waybar module** as a cheap second skin on the same Go daemon. Windows v1 = **Taskbar Flyout via Windows App SDK** but only after the Go daemon + relay client exist (WI-1); treat Windows as last due to signing/packaging cost (D5 source-first conflicts with MSIX signing — acceptable gap: side-load documented). STOP for a build plan: if the GNOME extension cannot run the Go daemon as a user service on vanilla Ubuntu, fall back to a systemd user unit + socket activation before any UI work.

## WI-3 — Web & mobile companion

### 3.0 Shared relay + web dashboard (Go + minimal web frontend)

- The same relay from WI-1 serves the dashboard and mobile apps; the dashboard is a read-only first cut (telemetry + roster), approvals are P2 behind auth.
- Web dashboard: single-page, no framework or a minimal one (D5 source-first; avoid heavy build chains), served by `bantay-bridge web`; authenticates with the same Noise pairing (paste 6-digit code → short-lived browser session). **Toolchain: Go (embed) + vanilla JS/CSS.** Effort M.

### 3.1 PromptCompiler (rule-based, shared by both mobile apps + devbox)

- D3 + D2: the task-spec JSON (`Goal` / `Files` / `Constraints`) is the shared schema; the compiler is deterministic, no LLM cleanup. Mode-B voice task structuring: dictation in → structured task spec out.
- One rule spec (ordered extraction rules over the dictation text: goal sentence detection, `@file`/`file:` mentions, constraint keywords like "don't touch", "only", "must not"), implemented **three times** — Swift (macOS/iOS), Kotlin (Android), Go (bridge). D3 explicitly accepts duplicated code across runtimes.
- **Toolchain**: Swift, Kotlin, Go. **Effort M.**
- RED tests: a shared fixture corpus (20+ dictation samples, including CJK/emoji noise) with expected Goal/Files/Constraints; each runtime's test asserts byte-identical output against the fixture. The voice floor is D3's (FluidAudio/Parakeet macOS 14+, Sherpa-ONNX Android); PromptCompiler is **decoupled from STT** — it consumes text, so it ships before the voice engines.

### 3.2 iOS companion (SwiftUI + ActivityKit + Dynamic Island)

- **Effort L. Toolchain: Xcode 15/16, iOS 17+ (ActivityKit needs iOS 16.1+; D3's FluidAudio floor is iOS 17), real device for Live Activities. Source-first D5: ad-hoc signing, no paid cert for dev; APNs push to refresh Live Activities needs a developer account — treated as optional P2, Live Activities can start locally.**
- Structure: `BantayCompanion` iOS app (SwiftUI) + widget extension (Live Activity rendering approval cards). Pairing UI (paste 6-digit code), approval 1-tap cards (`approve`/`deny`/`choice`/`multi` over the v2 command), offline queue, Dynamic Island collapses to "N pending" summary.
- Wire: same Noise-over-WSS client (Swift, Network.framework); E2E identical to WI-1.
- **Offline queue** lives in the shared app group container `<group.com.bantay>/outbox.jsonl` + `delivered.jsonl` (mirror of the Mac's `agent-events.jsonl` convention), so both the app and the widget extension can read pending state. BGTaskScheduler + reconnect-triggered flush; idempotency identical to WI-1 (`cmd_id` + ack + dedup).
- RED tests: outbox dedup logic and approval_id parsing as pure Swift; ActivityKit rendering covered by a fixture-driven state model test.
- **Failure modes**: iOS suspends the app → tunnel dies → Live Activity shows "queued" (persists through suspension), BGTask + push (P2) re-establishes; lost approval → unacked `cmd_id` re-sent on reconnect; Keychain token survives app kill, not device restore (re-pair required).

### 3.3 Android companion (Kotlin/Jetpack Compose)

- **Effort L. Toolchain: Android Studio, Kotlin 2.x, Compose, WorkManager, Android Keystore, foreground service.**
- Structure: foreground service (`START_STICKY`, type `dataSync`/`connectedDevice`) owns the Noise-over-WSS tunnel; Room DB tables `outbox` and `delivered`; Compose UI with approval cards; pairing via the same 6-digit code.
- **Offline queue**: Room is the durable queue; WorkManager (network-connected constraint) flushes; dedup is DB-level unique constraint on `cmd_id` — **approvals can never double-fire even across process kills**.
- **Failure modes**: Doze mode / OEM battery killers suspend the foreground service → WorkManager retries + `START_STICKY` restart; P2P tunnel dies on network change → reconnect with session-token refresh; token/keys live in Android Keystore (non-exportable); **gap**: OEM aggressive killing is un-ownable — document per-device battery-exemption instructions, accept partial failure.
- RED tests: Room outbox unique-constraint behavior, session refresh on reconnect, Keystore roundtrip, PromptCompiler fixture parity.

## Pairing & identity (shared design, all clients)

- **6-digit code**: generated on the Mac, shown in Settings; valid 10 min, single-use, max 5 attempts then invalidated. Low entropy (10^6) is acceptable because: rate-limited, one-time, short TTL, displayed only on the Mac, and the Noise XX handshake additionally requires possession of the code's derived pre-shared key — guessing the digits alone cannot complete the handshake.
- **Key persistence**: macOS — Keychain (`kSecClassGenericPassword`, service `bantay.pairing`) + device registry `~/Library/Application Support/Bantay-TUI/devices.jsonl`. iOS — Keychain + app-group container. Android — Android Keystore (non-exportable EC keypair) + EncryptedSharedPreferences for the session token. Go bridge — `~/.config/bantay/identity.json` (0600), keys never logged.
- **Revocation**: delete the device row from the Mac registry → its `device_token` becomes invalid at the relay. Revoked device cannot reconnect; its queued approvals are never delivered.
- **Clock skew for pairing**: the code is validated against the Mac's `begin` timestamp with a ±2 min grace window, not a strict TOTP window; session tokens carry issuer-issued nonces, not client clocks; `seq` counters are per-session monotonic, never wall-clock.

## Dependencies + execution order

| Order | Work item | Must exist first | Gate before starting |
|---|---|---|---|
| 0 | v2 wire-contract spec + Go module scaffold + shared fixtures | 015 (locked) | L61 RED for envelope parsing drafted |
| 1 | WI-1 bridge + relay + macOS pairing client | 0 | Go tests green on handshake vectors; harness ALL PASS |
| 2 | 3.1 PromptCompiler rule spec + triple implementation | 0 (independent of 1) | fixture corpus RED in all 3 runtimes |
| 3 | 3.0 web dashboard (read-only) | 1 | dashboard parses a recorded telemetry fixture |
| 4 | 3.2 iOS companion | 1, 3.1 | device paired; approval ack round-trip on real device |
| 5 | 3.3 Android companion | 1, 3.1 | device paired; foreground service survives screen-off 5 min test |
| parallel | WI-2 feasibility matrix | none (research) | deliverable is the doc itself |
| P2 | approvals in web dashboard; iOS push refresh; Android P2P tunnel | 3/4/5 | not phase-3 done criteria |

**STOP conditions** (report, do not improvise):
- If Noise handshake cannot be verified against published test vectors → STOP, do not hand-roll crypto, revisit library choice.
- If the relay must ever see plaintext (e.g. for message routing) → STOP; that breaks the E2E invariant; redesign routing to ciphertext headers only.
- If a mobile OS kills the queue and a `cmd_id` replays into an already-resolved prompt → STOP and fix dedup before anything ships (approval double-fire is the phase's cardinal sin).
- If the PromptCompiler fixture corpus diverges across runtimes → STOP; the schema (`Goal/Files/Constraints`) must be single-source.

## Effort + toolchain summary

| Item | Effort | Toolchain |
|---|---|---|
| v2 contract + Go scaffold | M | Go 1.22+, x/crypto, Noise |
| WI-1 bridge + relay + pairing | L | Go; herdr CLI; Swift (macOS client, Network.framework) |
| WI-2 overlay feasibility matrix | S | docs only |
| 3.0 web dashboard | M | Go embed + vanilla JS |
| 3.1 PromptCompiler (×3) | M | Swift, Kotlin, Go |
| 3.2 iOS companion | L | Xcode, iOS 17+, ActivityKit, Keychain, BGTaskScheduler |
| 3.3 Android companion | L | Android Studio, Kotlin, Compose, WorkManager, Keystore, foreground service |

## Gates (all items)

- Harness `ALL PASS` + adversarial corpus grows; RED-first for every block.
- Swift: `swift format lint --recursive --strict Sources Tests`, `swift build` (debug+release) 0 warnings.
- Go: `gofmt -l` empty, `go vet` clean, `go test ./...` green.
- No `bantayd`-style daemon split in the macOS core path (D1 enforcement); the Mac is a client of the relay, never a server beyond the existing localhost ingest.
- CI matrix extended with a Go job once `bridge/` lands.
