# Plan 021: Universal Quota Detection & BYOK Orchestration Pipeline

## Objective
Elevate Bantay-TUI's quota and rate limit tracking from synthetic approximations to high-fidelity, real-time multi-vendor telemetry (benchmarked against CodexBar, T3 Code, Capy, LiteLLM, and OpenRouter), integrating live countdowns, prompt caching economics, and quota-aware automated task orchestration.

---

## Architecture & Work Breakdown

### Task 1: Claude Code Real-Time Hook Ingestion & Telemetry Adapter
- **File:** `Sources/BantayTUI/UniversalQuotaAdapters.swift`
- Create `ClaudeUsageAdapter`:
  - Read Claude Code `rate_limits` JSON payload (`five_hour` and `seven_day` `used_percentage` and `resets_at` timestamps).
  - Support two ingestion pathways:
    1. Read cached state file at `~/.claude/rate_limits.json` (or `~/.claude/statusline-output.json`).
    2. Add endpoint `POST /telemetry/claude` in `EventIngestServer.swift` for direct push from Claude Code's `statusLine` command.
  - Parse exact remaining percentages and calculate minute-accurate `resetsAt` timestamp.

### Task 2: OpenRouter & Gateway BYOK Quota Probing
- **File:** `Sources/BantayTUI/UniversalQuotaAdapters.swift`
- Create `OpenRouterUsageAdapter`:
  - When `OPENROUTER_API_KEY` is present in environment or config, query `https://openrouter.ai/api/v1/key`.
  - Parse `limit`, `limit_remaining`, and `limit_reset` into `ProviderQuota`.
  - Track total dollar balance and monthly consumption.
- Create `OllamaUsageAdapter`:
  - Probe local Ollama daemon (`http://localhost:11434/api/ps`).
  - Report active local models, context limits, and zero-cost unlimited quota.

### Task 3: Enhanced Prompt Caching & Token Economics
- **File:** `Sources/BantayTUI/UsageTracker.swift` and `UniversalQuotaAdapters.swift`
- Upgrade token tracking model:
  - Add explicit token classes: `inputTokens`, `outputTokens`, `cachedReadTokens`, `cachedWriteTokens`.
  - Compute model-specific cost with cache discounting (e.g. Claude 3.5 Sonnet / Codex cache reads at 90% discount).
  - Update `CodexDeepTelemetry` and `CursorDeepTelemetry` to report cached token savings.

### Task 4: Dynamic Live Reset Countdowns in UI
- **Files:** `Sources/BantayTUI/QuotaAxiTracker.swift`, `Sources/BantayTUI/ProviderQuotaView.swift`, `Sources/BantayTUI/NotchStatusView.swift`
- Add `resetsAt: Date?` and `isCooldown: Bool` to `ProviderQuota`.
- In `ProviderQuotaView.swift`:
  - Replace static `resetHint` strings with dynamic countdown timers (e.g., `"Resets in 1h 24m"`, `"Resets in 15m"`).
  - Highlight imminent resets with pulse / amber accents.
- In `NotchStatusView.swift`:
  - Surface active provider quota exhaustion directly in the shelf header and compact island when approaching limits.

### Task 5: Quota-Aware Task Orchestration & Failover
- **File:** `Sources/BantayTUI/TaskDispatcher.swift`
- Implement intelligent provider routing:
  - Check active target provider quota status before dispatching.
  - If target provider is `isCritical` ($\le 5\%$) or in 429 cooldown, trigger **automated fallback routing**:
    - Default chain: `Claude Code` $\rightarrow$ `OpenAI Codex` $\rightarrow$ `Antigravity` $\rightarrow$ `Ollama`.
  - Record 429 errors from `AgentDetector.swift` transcript scanner to put the provider in temporary quarantine until its reset timestamp.

### Task 6: Unit Testing & Logic Harness Validation
- **Files:** `Tests/BantayTUILogicTests/QuotaAxiTests.swift`, `.kilo/LogicCheck.swift`
- Add **Layer 151** to `.kilo/LogicCheck.swift` asserting:
  - Claude Code rate limit JSON parsing (`five_hour` percentage and `resets_at` Date).
  - OpenRouter `/key` response parsing.
  - Live reset countdown calculation.
  - Quota-aware task dispatch failover.
- Run `scripts/build-logic-harness.sh`, `swift test`, and strict `swift format lint`.

---

## Verification Criteria
1. `ClaudeUsageAdapter` successfully parses live `rate_limits` JSON into exact percentage and `resetsAt` date.
2. `ProviderQuotaView` displays dynamic countdowns (`"Resets in Xh Ym"`).
3. `TaskDispatcher` reroutes tasks when a primary provider is in `isCritical` or cooldown state.
4. All layers in `scripts/build-logic-harness.sh` pass with `ALL PASS`.
5. Strict `swift format lint --recursive --strict Sources Tests` passes with zero warnings.
