# TEAMWORK.md - Antigravity quota decode

## Objective

Make Antigravity's provider-reported quota visible in the Bantay notch. Decode the IDE-cached `userStatus` protobuf into remaining percent and reset time, show it as a provider quota row beside the existing measured usage row, and never fabricate a number. Land through review with the full suite and logic harness green, then prove the release build renders the row.

## User and job

Primary user: a developer who runs several coding agents at once and treats the notch as the control plane.

Job statement: "When I am deciding where to send work, I want to see Antigravity's real remaining quota and reset time in the notch, so I can route work without opening the IDE or guessing."

- Functional job: know remaining capacity and when it resets, in one glance, without leaving the current task.
- Emotional job: trust the number. A wrong or invented percentage is worse than no row.
- Social job: the notch is the single source of truth for agent state, so Antigravity must not look like a second-class citizen.

## Constraints

- Read-only access to Antigravity stores. Never write to the IDE database.
- No account email, token, or real blob in logs, tests, fixtures, or commits.
- No fabricated percent, reset time, token count, or cost.
- Sessions keep zero-token rows with honest labels.
- IDE conversation store stays canonical. CLI store stays out of scope.
- No new third-party dependency. SQLite3 is already linked.
- No em dashes in added content.
- One writer per file.
- Full gate: format lint, build, full test suite, logic harness.
- Landing: logical commits on the branch, one PR, merge only after CI is green.
- Live proof: release install, control-socket or log probe, plus one user screenshot.

## Acceptance criteria

| ID | Criterion | Independent check | Owner |
| --- | --- | --- | --- |
| AC1 | A decodable `userStatus` blob yields the exact remaining percent the IDE reports for the same blob. | Synthetic blob test asserts the exact value. A second decoder written separately (Python, different protobuf path) is run against the same bytes and must agree. | technical scout, then auditor |
| AC2 | A decoded reset timestamp becomes the exact expected `Date`; a missing reset yields `nil`, not a guess. | Unit test with a fixed epoch plus a separate date conversion check. | worker |
| AC3 | Absent or undecodable `userStatus` emits no provider row; a measured usage row still appears when conversations exist; an empty home emits no Antigravity row at all. | Three temp-home tests: decodable, corrupt, absent. Existing empty-home harness check stays green. | worker |
| AC4 | No personal data leaves the machine. Fixtures are synthetic. | `git diff` scan for email patterns and the known account string; test fixtures reviewed by hand; no blob dumps in logs. | auditor |
| AC5 | When decode succeeds, the Quotas panel shows two distinct Antigravity rows: provider quota with reset, and measured usage. | View-model or state test asserts both rows and distinct labels; live probe prints both. | worker, then live probe |
| AC6 | Antigravity session rows stay zero-token and unchanged. | Existing session tests pass; diff review confirms no token or cost invention. | critic |
| AC7 | Format lint, build, full suite, and harness all pass. | `swift format lint --recursive --strict Sources Tests`; `swift build`; full `swift test`; `bash scripts/build-logic-harness.sh` returns `ALL PASS`. | auditor |
| AC8 | The installed release renders the new row on this machine. | Release build, `scripts/setup.sh`, process check, log or control-socket probe showing the provider row, plus a user screenshot. | captain, user |
| AC9 | The change reaches `main` through a green PR. | `gh pr checks` green and merge commit present on `main`. | captain |

## Non-goals

- CLI store merge or reconciliation.
- Event adapter, hook install, or decision transport for Antigravity.
- Token or cost attribution for Antigravity sessions.
- Quotas panel redesign beyond adding the row.
- Identifier, bundle ID, or data path migration.
- Fixing unrelated live-data test flakiness.

## Locked decisions

- Scope is the quota decode only.
- Show both rows: provider quota and measured usage.
- Keep zero-token session rows.
- IDE store is canonical.
- Land by PR and merge after green.
- Live proof requires an installed release plus a probe plus a user screenshot.

## Decode findings (T1)

- Store: `~/Library/Application Support/Antigravity IDE/User/globalStorage/state.vscdb`, table `ItemTable`, key `antigravityUnifiedStateSync.userStatus`.
- Encoding: the value is base64 of a protobuf wrapper, field 1 -> field 2 -> field 1 -> base64 payload -> protobuf.
- Payload: field 33 is the model container. Repeated field 1 entries carry a model name (field 1) and quota info (field 15). Quota field 1 is a 32-bit float `remainingFraction` (0...1). Quota field 2 is a timestamp message whose field 1 is int64 epoch seconds. Field 36.2 is the plan tier.
- Observed on this machine: 10 models, all `remainingFraction = 1.0`, all reset at 1793622419 = 2026-11-02T12:26:59Z. The check ran at 2026-11-03T05:22Z, so the cached window was already stale.
- Credit counts exist in `modelCredits` and tier field 14, but the amount and minimum mapping is not proven. This increment does not guess them.
- The blob contains the account email. It is never logged, tested with, or committed. Fixtures are synthetic.

## Phase 2 and 3 decisions

- Scouts covered user, market, technical, design, distribution, risk, and alpha. The technical scout had no shell, so the captain decoded the blob directly with a redacting parser.
- Theses: A minimal honest provider row, B grouped Antigravity card, C credit-aware API-first.
- Blind judge picked A as the base. One graft from B: group the two rows under one Antigravity header with Reported and Measured labels. No graft from C: the credit mapping is unproven and would violate the no-fabrication rule.
- The judge's first failing test: lower-fraction model with a later reset must return that model's own reset, and a past reset must be flagged stale.

## Phase plan

1. Scope: this file. Done.
2. Fan out: seven scouts (user, market, technical, design, distribution, risk, alpha). Each returns finding, evidence, implication, one bet.
3. Choose: blind judge picks one base thesis and at most two grafts.
4. Execute: disjoint file ownership, implementation, challenger stress test, critic review, auditor verification.
5. Integrate: verify against AC1 to AC9, install release, probe, request screenshot, open PR, merge.

## Draft file ownership

| File | Owner |
| --- | --- |
| `Sources/BantayTUI/AntigravityQuota.swift` (new) | implementation worker |
| `Sources/BantayTUI/QuotaAxiTracker.swift` | implementation worker |
| `Tests/BantayTUILogicTests/QuotaTrackerTests.swift` | implementation worker |
| `.kilo/LogicCheck.swift` | harness worker |
| `plans/022-antigravity-full-integration.md`, `CHANGELOG.md` | docs worker |
| `TEAMWORK.md` | captain |

No two writers on one file. The existing uncommitted tree is committed as logical slices before the new increment starts.

## Risks

- Protobuf schema drift. Unknown fields must be tolerated, not crash the reader.
- Live SQLite WAL. A locked or missing database must read as no data, never an error surfaced as a fake zero.
- Privacy. The blob contains the account email. Decode from a copy, report field numbers only, never values that identify the account.
- Meaning drift. A percent field could mean used instead of remaining. AC1's independent decode must settle the direction, not a guess.
- Mixed dirty tree. Committing 28 existing files plus the new increment in one PR hides review. Logical commits are mandatory.
- Live-data test flake outside the increment. Report as evidence, do not widen scope.

## Evidence log

Fill during Phase 4 and Phase 5.

| Check | Command or artifact | Result |
| --- | --- | --- |
| baseline diff | `git diff --check` | clean at base commit `d07fac9` |
| decode agreement | Swift reader vs independent Python decoder | both: 100%, reset epoch 1793701558, 10 models, tier Google AI Pro, stale false |
| targeted tests | `swift test --filter AntigravityQuotaTests` | 8 tests passed after wrapper fix; 29 in 2 suites before it |
| format and build | `swift format lint --strict`; `swift build` | both clean |
| full suite | `swift test` | 208 tests in 18 suites passed |
| harness | `scripts/build-logic-harness.sh` | `ALL PASS` |
| release install | PID and log probe | pending |
| screenshot | user-provided | pending |
| PR | `gh pr checks` | pending |

## Open questions

None blocking. Deferred follow-ups: CLI reconciliation, decision transport, token attribution.
