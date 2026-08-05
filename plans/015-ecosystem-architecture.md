# Plan 015 — Bantay ecosystem architecture & language boundaries

Status: locked. Architecture decisions ratified 2026-08-04. This plan is the
master document; per-phase execution plans live in 016 (macOS completion),
017 (multiplexer & local ecosystem), 018 (remote & cross-platform) and are
written by dedicated planning agents. No code lands without its RED test
(`plans/006-test-harness-sdd.md`).

## The product invariant

Bantay is a **control plane for AI coding agents, reachable from anywhere**.
The macOS notch island is the primary surface; the phone is not a feature, it
is the point. Every architecture decision below serves that invariant.

## Locked decisions

### D1 — Language boundary (the rule that governs all code)

- **Swift owns every Apple UI surface.** The notch island, Settings, the iOS
  companion (ActivityKit/Live Activities), CoreML voice. Non-negotiable —
  SwiftUI/AppKit/NSPanel cannot be Go, and the island stays single-process
  (no `bantayd` daemon split; a daemon-down death path is a regression).
- **Go owns every cross-platform surface.** Standalone TUI (bubbletea),
  remote devbox/SSH bridge, P2P mesh (pion/webrtc, wireguard-go), Linux/Windows
  overlays. One binary, trivial cross-compile, goroutines map to the
  offline-queue-then-flush pattern.
- **Never both in the macOS app's core path.** Go appears only where a
  non-Apple runtime is required. No `bantayd` rewrite of the current app.

### D2 — The wire contract is the seam

Swift and Go interoperate only through explicit contracts:

1. **NDJSON socket protocol** (already in `HerdrSocketClient.swift`) — the
   event/command transport. Versioned; unknown fields ignored, unknown methods
   rejected (`L19` tests already enforce framing).
2. **Task-spec JSON** (`Goal` / `Files` / `Constraints`) — the shared format
   both mobile apps and the PromptCompiler emit, and herdr/agents consume.
   Single schema, both runtimes. The PromptCompiler is **rule-based**
   (deterministic, no LLM cleanup pass) per the Resonant pattern.

### D3 — Voice stack (two runtimes, one model family, one invariant)

- **Apple:** FluidAudio (Apache-2.0) + Parakeet. Verified portable: FluidAudio
  declares macOS 14 + iOS 17, and its bundled `NemoTextProcessing.xcframework`
  (v0.3.0, checksum-pinned) ships ios-arm64, ios-arm64-simulator, macos slices
  — the no-LLM text cleanup is mobile-portable.
- **Android:** Sherpa-ONNX + Parakeet-V3-ONNX + Silero VAD (Kotlin). Same model
  family, different runtime — accuracy parity, code duplicated by necessity.
- **Invariant:** no LLM cleanup pass on the dictation path. Direct STT only.
  PromptCompiler (task structuring) is rule-based; never a hosted model.
- **Costs accepted:** FluidAudio raises the voice floor to macOS 14 (rest of
  app stays 13, gated `#available`); ~735MB Parakeet model download on first
  run (show model + size, ask before downloading); model revisions/checksums
  must be pinned (Parakeet requires attribution).

### D4 — Resonant reuse (take 3, reject the rest)

- Take: `AudioCuePlayer` (synthesized cues, 288 LOC), the rule-based
  dispatch-intent pattern (port the pattern, not the code), FluidAudio as the
  voice engine.
- Reject: the app shell, meetings/transcription product, cloud/analytics
  (PostHog/Sentry/Convex), notch visuals (Bantay's island already ahead).

### D5 — Distribution stance

- Source-first; no Apple Developer cert required. Ad-hoc signed zip + cask
  with documented one-time Gatekeeper bypass. Release workflow (PR #23) pushes
  a `release/cask-vX.Y.Z` branch + PR; main is PR-protected.
- Sparkle auto-update remains P2 for the macOS app once releases exist.

## Roadmap phases (detailed plans in 016–018)

| # | Phase | Runtime | Plan |
|---|-------|---------|------|
| 1 | macOS completion & hardening (stability, Sparkle, deeper UI, multi-display/a11y) | Swift | 016 |
| 2 | Multiplexer adapters, universal hook SDK, standalone TUI | Swift (in-app) + Go (TUI) | 017 |
| 3 | Remote devbox/SSH bridge, cross-platform overlays, web/mobile companion | Go (bridge/mesh) + Swift (iOS) + Kotlin (Android) | 018 |

## Gates (all phases)

- Harness `ALL PASS` (`.kilo/LogicCheck.swift`) — RED tests first, adversarial
  corpus grows per phase.
- `swift format lint --recursive --strict Sources Tests` — clean.
- `swift build` debug + release — 0 warnings.
- Go: `gofmt -l` empty, `go vet` clean, `go test ./...` green (when Go code lands).
- CI matrix (macOS 15 fast path + macOS 13/Intel queued leg) + launch smoke.

## Accepted risks

- FluidAudio binary xcframework is not compiled locally — pin checksums in
  Package.resolved discipline; record the pinned revision.
- Model weights are a supply-chain duty (Hugging Face, mutable) — pin revisions,
  preserve model cards/notices, show terms before download.
- iOS 17+ / macOS 14+ floors for voice — gated, never forced on older systems.
- Android = full second build track (foreground service, P2P client, STT) sharing
  only the wire contract + task spec with iOS — budget it as such.
- Go adoption must not touch the single-process macOS core; enforcement is
  review-level (any new `bantayd`-style daemon split requires a plan amendment).
