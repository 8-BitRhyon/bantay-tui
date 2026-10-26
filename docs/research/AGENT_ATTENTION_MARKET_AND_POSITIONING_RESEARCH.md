# Agent Attention Market and Positioning Research

- **Date:** 25 October 2026
- **Status:** Decision support
- **Scope:** macOS AI coding agent attention, approval, and audit market
- **Prepared for:** Bantay-TUI

> The notch is a delivery surface, not the product. The product is the decision loop: request, context, policy, decision, acknowledgment, audit.

## 1. Executive summary

The market for AI coding agents is large and growing. It is also crowded at the exact layer Bantay occupies.

JetBrains reports that 90 percent of professional developers used AI coding agents at work each week in mid-2026. Stack Overflow reports that 59 percent of technologists use agents at work. The important number for Bantay is not adoption. It is trust. Stack Overflow also reports that 63 percent of technologists rarely or never let agents run fully on autopilot. 60 percent block agents from making unapproved system changes. 68 percent prefer single-agent setups.

These numbers describe an attention and approval problem. They do not describe a dashboard problem.

The notch monitor category formed in April 2026. CodeIsland, Open Island, and Ping Island launched within days of each other. All three are free and open source. All three already support approvals, questions, terminal jump, and broad agent coverage. CodeIsland adds iPhone, Apple Watch, ESP32, SSH, push, and webhook forwarding. Open Island adds an external display fallback and 15 agents. Ping Island adds SSH and 20 or more clients. Vibe Island sells a polished notch panel for 19.99 US dollars. AgentNotch sells one for 9.99 US dollars. Crest sells a broader notch utility for 14.99 US dollars.

Bantay is not ahead on features. It is behind on structured approvals, setup, release, and distribution.

Bantay does have real strengths. The native craft is good. The approval queue, multi-select grid, free-text reply, risk badge, review-only waits, and retry UI are substantial. So are the idle strip styles, window manager, quota ledger, task manager, CLI, and control socket. The problem is focus and proof.

The most important finding in this report is technical. Bantay's approval path usually reads the terminal, then sends `y`, `n`, or a number key to the terminal. It does not receive a decision acknowledgment from the agent. Its MCP approval tool appends an event and returns immediately. Its Claude hook posts an event and returns no permission decision. The UI can say "delivered" before the adapter action completes. It has no proof that a key was sent or that the agent accepted the decision.

That means the current "honest delivery" claim is stronger than the implementation supports. This is fixable. It is also the best opportunity.

The winning position is not "another notch app." It is the approval inbox for engineers who already have agents, terminals, and scripts. The promise is simple: one inbox, exact context, a reliable decision, and a receipt. The notch is how the inbox reaches the user. It is not the category.

Engineers with homegrown tools will not switch wholesale. They will replace one layer if it is clearly better, non-destructive, inspectable, and scriptable. Bantay should be that layer. It should plug into their setup, not replace it.

The license is a live contradiction. The repository is public MIT. The stated strategy is proprietary. The repository has one human contributor, no releases, no tags, 0 stars, and 0 forks. MIT is irrevocable for existing copies. The owner can relicense future versions, but cannot revoke rights already granted. The right time to decide is before the first public release.

The release path is also incomplete. The Cask file contains a placeholder SHA. The tap repository does not exist. The release workflow has never run. The README advertises a Homebrew install that cannot work as written.

### 1.1 Bottom line

Bantay should compete as an approval and attention layer, not as a notch monitor. It should win on four things:

1. One inbox for every agent and terminal.
2. Exact context for every request.
3. A reliable decision with an agent acknowledgment.
4. A receipt and audit trail for every decision.

The product should be local-first, scriptable, and protocol-native. It should support ACP for structured agent permissions, AG-UI semantics for interrupts and resume, and MCP for tool-facing approvals. It should publish an open Attention Event schema and a Decision Receipt schema.

The first release should not add more agents. It should make the top three agents trustworthy.

### 1.2 Decision summary

| Decision | Recommendation | Main reason |
|---|---|---|
| Category | Approval inbox and attention layer | The monitor layer is free and crowded |
| First user | Senior macOS engineer with 2 to 5 agents | Fits the product's strengths and the pain |
| Approval transport | Blocking hooks first, then ACP | Keystrokes cannot prove a decision |
| Proof | Decision receipt and audit log | The clearest gap in the market |
| License | Source-available or open-core | The audience trusts inspectable tools |
| Price | 29 to 39 US dollars one-time for Pro | Market anchors are 9.99 to 19.99 |
| Team revenue | Audit and policy subscription later | Recurring value needs team scope |
| Distribution | Ship a signed release in 2 weeks | No release means no adoption |

### 1.3 What would make Bantay special

Bantay becomes special when it is the only place where an engineer can see every agent request and decide with exact context. It must also prove the decision was accepted, while the engineer keeps their own terminals and scripts.

That is a defensible sentence. "Another notch app with more agents" is not.

## 2. Method and evidence standard

This report uses four kinds of evidence.

Primary market data comes from JetBrains and Stack Overflow surveys. Protocol data comes from the official ACP, AG-UI, MCP, A2A, and OpenTelemetry specifications. Competitor data comes from primary READMEs, websites, pricing pages, GitHub metadata, release assets, and Homebrew analytics. Bantay data comes from source review, repository metadata, and the release workflow.

The report separates claims from proof.

| Evidence grade | Examples | Use |
|---|---|---|
| Strong | JetBrains survey, Stack Overflow survey, protocol specifications, source code | Facts and technical constraints |
| Medium | Vendor pricing pages, GitHub stars, release downloads, Homebrew installs | Direction and scale |
| Weak | Vendor comparison pages, testimonials, feature counts | Existence and positioning only |

Stars are not users. Downloads are not unique users. Homebrew installs are a lower bound. Vendor comparison pages are marketing.

One comparison page is clearly inaccurate. Vibe Island's comparison says AgentNotch supports 2 agents and has no approvals or question answering. AgentNotch's own site lists Claude Code, Cursor, Codex, Kimi, OpenCode, Antigravity, Pi, Cowork, Conductor, and herdr. It also documents approvals and questions. The same page says Open Island has no question answering. Open Island's README documents question flows for OpenCode and human-in-the-loop approvals for Hermes.

This report does not use those comparison tables as capability truth.

### 2.1 Limitations

No competitor publishes revenue, paid users, or retention. Paid demand is therefore unproven in public data. GitHub stars and release downloads are proxies, not revenue. Homebrew analytics undercount direct downloads. There are no Bantay user interviews yet. The recommendations are a thesis to test with design partners, not a forecast.

## 3. Market context

### 3.1 Adoption is large and daily

| Data point | Value | Source |
|---|---|---|
| Professional developers using agents weekly | 90 percent | JetBrains, 15,000 or more respondents |
| Professional developers using agents daily | 68 percent | JetBrains |
| Technologists using agents at work | 59 percent, up from 31 percent | Stack Overflow pulse, 1,100 respondents |
| AI users using coding agents daily | 73 percent | Stack Overflow 2026 |
| Daily AI users spending 4 or more hours | 31 percent | Stack Overflow 2026 |
| Coding assistants and agents as top AI use case | 66 percent | Stack Overflow 2026 |
| Claude Code adoption at work | 39 percent | JetBrains |
| Codex adoption at work | 16 percent | JetBrains |
| GitHub Copilot adoption at work | 21 percent | JetBrains |
| Cursor adoption at work | 12 percent | JetBrains |
| OpenCode adoption at work | 7 percent | JetBrains |

Stack Overflow reports a different Claude Code share, 66 percent, because its base is coding agent users, not all professional developers. The two numbers are not contradictory. They answer different questions.

The key market fact is not that agents are popular. It is that most users still run one agent at a time. 68 percent prefer predictable single-agent setups. Multi-agent users are a minority, but they are heavy users. They use agentic workflows daily more often than single-agent users.

Bantay should not lead with a claim of 30 agents. It should lead with one inbox for the agent you already use. Multi-agent support is a retention feature. It is not the entry point.

### 3.2 Trust is the bottleneck

| Data point | Value | Source |
|---|---|---|
| Rarely or never let agents run fully on autopilot | 63 percent | Stack Overflow pulse |
| Block agents from unapproved system changes | 60 percent | Stack Overflow pulse |
| Prefer single-agent setups | 68 percent | Stack Overflow pulse |
| Strongly agree security is a barrier | 44 percent, down from 56 percent | Stack Overflow pulse |
| Strongly agree accuracy is a barrier | 47 percent, down from 57 percent | Stack Overflow pulse |
| Trust AI when answers are easy to validate | 48 percent | Stack Overflow 2026 |
| Trust AI for most non-important tasks | 16 percent | Stack Overflow 2026 |

The human-in-the-loop model is the norm. Users do not want more autonomy. They want better control at the moment of decision.

This is the strongest argument for an approval inbox. It is also a warning. More approval prompts can make the problem worse. The product must reduce blind approvals, not increase prompt volume.

### 3.3 Switching behavior

Stack Overflow asked developers why they switched AI tools in the past year.

| Reason | Share |
|---|---|
| Better output quality | 25.1 percent |
| Organization required it | 11 percent |
| Better integration with workflow or development environment | 7.4 percent |
| Lower cost | 6 percent |
| Better support for agents, automation, or coding workflows | 3.7 percent |
| Better security, privacy, or compliance | 2.2 percent |
| Did not switch | 34 percent |

The largest reason is output quality. A UI tool cannot claim better model output. It must claim better workflow integration, fewer missed blocks, and lower risk.

Only 7.4 percent switched for better integration. That is both an opportunity and a caution. The market is not desperate to switch. Bantay must create a new behavior, not steal a large existing budget.

The practical motion is additive. Engineers can install Bantay alongside their scripts. The product can prove value before asking them to remove anything. That is why "replace your glue, not your workflow" is a stronger adoption story than "replace your agent dashboard."

### 3.4 Why now

Five changes make this moment attractive.

1. Agents run longer and ask more permissions.
2. Multiple agents and remote sessions create more blind spots.
3. Security teams scrutinize agent actions more closely.
4. Protocols now standardize structured permissions and interrupts.
5. Native notch apps are normal, so the UI no longer needs to be explained.

The window is also closing. The category formed in April 2026. Competitors ship every week. A late entrant without a release cannot win on feature count.

## 4. Competitive landscape

### 4.1 Category map

The market has five layers.

| Layer | Products | What they own |
|---|---|---|
| Notch monitors and approval panels | CodeIsland, Open Island, Ping Island, Vibe Island, AgentNotch, Crest, ClaudeNotch, NotchAgent, Bantay | Attention and quick decisions |
| Agent harnesses | T3 Code, Conductor | The full agent workflow |
| Terminals | cmux, Ghostty, iTerm2, Warp | The execution surface |
| Voice and ambient layers | Heard | Spoken status and voice control |
| Native agent interfaces | Claude Code, Codex, Cursor, Copilot | The agent's own approval UI |

Bantay sits in the most crowded layer. It also has the least distribution in that layer.

### 4.2 Direct notch competitor matrix

| Product | Price and license | Agent coverage | Structured approvals | Questions and multi-select | Remote or mobile | Main gap |
|---|---|---|---|---|---|---|
| CodeIsland | Free, MIT | 30 or more tools | Yes, for blocking-hook tools | Yes, multi-question | SSH, iPhone, Watch, ESP32, push | Some tools are observe-only |
| Open Island | Free, GPL-3.0 | 15 agents | Yes, for some tools | Partial | SSH, external display | Some integrations are fire-and-forget |
| Ping Island | Free, Apache-2.0 | 20 or more clients | Yes, for supported tools | Yes | SSH bridge | No native mobile app |
| Vibe Island | 19.99 USD one-time, 1 Mac, 1 year updates | 30 agents | Yes | Yes, plan review | SSH, iPhone via Bark | Closed source, no audit or policy |
| AgentNotch | 9.99 USD one-time, 14-day trial | 9 or more agents and integrations | Yes | Yes | Menu bar, sessions | No audit, fewer agents |
| Crest | 14.99 USD one-time | Claude Code, Codex, Copilot CLI | Yes | Yes | Broad notch utility | Not cross-agent, no audit |
| ClaudeNotch | Source-available, noncommercial | Claude Code, Codex beta | Yes, blocking | Yes, typed answer | Local only | Claude-first focus |
| NotchAgent | Free, Apache-2.0 | herdr only | Yes | Yes | SSH | herdr-only |
| Bantay | MIT, no release | Broad claims | No, mostly keystrokes | Yes in UI, transport fragile | ntfy actions | No decision proof, audit, or release |

CodeIsland is the most complete free competitor. Its README claims 30 or more AI coding tools, approvals, multi-question prompts, exact terminal jump, SSH, and iPhone and Watch companions. It also claims ESP32 support, push to multiple services, webhook forwarding, and signed notarized builds. It has 30 releases and 42,943 release asset downloads. Its main weakness is that some tools cannot carry a decision through hooks, so it observes only.

Open Island is the strongest open-source alternative. It has 15 agents, 15 or more terminals and IDEs, a non-notch fallback, approvals for several agents, and a clean local-first story. It has 30 releases and 24,302 release asset downloads. Its main weakness is uneven decision support across integrations.

Ping Island is the tinkerer's option. It supports 20 or more clients, SSH bridging, auto-approve, custom themes, sounds, and mascots. It is Apache-2.0 and has 30 releases. Its main weakness is the lack of a native mobile app and audit layer.

Vibe Island is the premium paid option. It sells 30 agents, 20 or more terminals, approvals, questions, plan review, usage tracking, SSH, and local-only operation for 19.99 US dollars. The price includes one Mac and one year of updates. Its main weakness is that it is closed source and has no audit or policy engine.

AgentNotch is the low-price paid option. It sells approvals, questions, sessions, and plan limits for 9.99 US dollars. It is a companion, not a replacement. Its main weakness is limited agent coverage and no audit.

Crest is the broad notch utility. It sells file drop, passwords, two-factor codes, widgets, and agent approvals for 14.99 US dollars. Its main weakness is that agent approvals are one feature in a larger utility, not a focused product.

ClaudeNotch is the specialist. It supports Claude Code permission prompts, questions, diffs, deny reasons, Touch ID, and spend caps. It is source-available for noncommercial use. Its main weakness is single-agent focus.

NotchAgent is the herdr specialist. It supports approvals, questions, SSH, and a screen saver for herdr sessions. It is Apache-2.0. Its main weakness is herdr-only coverage.

### 4.3 Adjacent platforms

| Product | Price and license | What it does | Why it matters |
|---|---|---|---|
| T3 Code | Free, open source | Agent harness control surface with mobile, web, and desktop apps | Owns the full workflow, not just attention |
| Conductor | Free local, 50 USD per month Pro, 60 USD per user per month Teams | Parallel agents in isolated workspaces | Owns the workspace and review flow |
| cmux | Free, GPL | Terminal with agent notifications and a socket API | Owns the execution surface |
| Heard | Free engine, 24 USD per month Power | Voice layer for agent status and control | Owns the ambient, eyes-off channel |
| Native agent UIs | Included with agents | Native approvals and questions | The default competitor |

T3 Code and Conductor are not notch apps. They are workflow replacements. They show that developers will adopt a new surface when it owns a complete job. They also show the risk of a broad product. Bantay cannot out-execute a funded harness on its own turf.

cmux is the most important adjacent threat. It is a terminal with notifications, a socket API, and a large open-source following. Its README says the best developers have always built their own tools. It argues that closed products have not solved agent workflows. That is a direct challenge to a closed, opinionated dashboard.

Heard shows that recurring revenue is possible when the product provides an ongoing service. It charges 24 US dollars per month for managed voices, cloud narration, and mobile control. A local-only UI cannot charge the same way without a team or audit service.

### 4.4 Saturation evidence

| Product | Created | Stars | Forks | Releases | Downloads | License |
|---|---:|---:|---:|---:|---:|---|
| CodeIsland | 6 April 2026 | 2,518 | 321 | 30 | 42,943 | MIT |
| Open Island | 2 April 2026 | 2,054 | 356 | 30 | 24,302 | GPL-3.0 |
| Ping Island | 3 April 2026 | 1,136 | 126 | 30 | Not used | Apache-2.0 |
| ClaudeNotch | 17 May 2026 | 55 | 3 | 30 | 111 | Source-available |
| NotchAgent | 18 July 2026 | 43 | 3 | 16 | 1,638 | Apache-2.0 |
| T3 Code | 8 February 2026 | 30,164 | 8,087 | 30 | Not used | Open source |
| cmux | 28 January 2026 | 28,473 | 2,585 | Many | Not used | GPL |
| Bantay | 28 July 2026 | 0 | 0 | 0 | 0 | MIT |

The download counts are release asset downloads, not unique users. Ping Island and the large harnesses are omitted because their asset counts are not comparable.

The pattern is clear. The free competitors have more stars, more releases, and more distribution. Bantay has none of those advantages yet.

Homebrew analytics give a rough lower bound on distribution. Crest, a paid notch utility, had 70 installs in 30 days and 72 in 365 days. The free cmux had 5,172 and 59,924. Claude Code had 60,330 and Codex had 157,022. The paid notch category is small compared with agent CLIs. These numbers are installs, not users or revenue.

### 4.5 What competitors do better

| Capability | Who does it better | Why it matters |
|---|---|---|
| Structured approval round-trip | CodeIsland, ClaudeNotch, Open Island, Ping Island, Vibe Island | The agent receives the decision, not a keystroke |
| Zero-config setup | Vibe Island, CodeIsland | The first approval happens without editing config |
| Mobile and remote | CodeIsland, Vibe Island, Ping Island | The user can leave the Mac |
| Diff and plan context | ClaudeNotch, Vibe Island, CodeIsland | The user decides with evidence |
| Distribution | CodeIsland, Open Island, Ping Island | Homebrew, signed builds, auto-update, frequent releases |
| Trust | CodeIsland, Open Island, ClaudeNotch | Open or source-available code |
| Notch craft | Vibe Island, Bantay | The surface feels native and responsive |

Bantay's remaining advantages are mostly craft and breadth, not category ownership.

### 4.6 Bantay's real advantages

Bantay does several things that competitors do not combine.

| Advantage | Evidence | Strategic value |
|---|---|---|
| Native queue and one-card triage | ApprovalCardView and NotchStatusView | Good foundation for an inbox |
| Multi-select and free-text reply | ApprovalCardView, AgentRowView | Covers more request types |
| Review-only fallback | ApprovalPromptResolver | Avoids blind approval on ambiguous prompts |
| Risk badge and second confirm | AgentPresentation, NotchHUDConfig | Good trust primitive |
| Idle strip modes | NotchIdleStripView, SettingsView | User control and polish |
| Window manager | StripWindowManager, README | Unique but orthogonal |
| Quota and session ledger | QuotaMonitor, UsageTracker | Useful, but table stakes |
| CLI and control socket | ControlGateway, README | Strong fit for tinkerers |
| MCP server | BantayMCPServer | A start, but not a real approval server |
| Hook SDK | HookSdk | A foundation for integrations |
| ntfy actions | EventIngestServer | Remote decisions without a native app |

The craft is real. The problem is that craft is not a moat. A competitor can copy a queue or a multi-select grid. A decision receipt and a protocol ecosystem are harder to copy.

## 5. What Bantay actually has

This section checks the product claims against the code. It does not assume the README is accurate.

### 5.1 The approval path

The current approval path works like this.

1. A hook or event source reports that an agent is blocked.
2. `ApprovalPromptResolver` reads the terminal tail or transcript.
3. The resolver extracts a request, choices, and a risk level with keyword lists and regular expressions.
4. The card shows the request and action buttons.
5. `AgentEventManager.approve` starts the active adapter action.
6. The tmux, Herdr, and Zellij adapters schedule `send-keys` commands with `y`, `n`, or a number.
7. OpenCode writes a decision file. Standalone agents receive synthetic keyboard events.
8. `approveResult` returns delivered immediately after scheduling the action. It does not wait for the adapter or the agent.

This is terminal automation with one file-based exception. It is not a structured approval protocol.

The consequences are concrete.

| Failure mode | What happens |
|---|---|
| The agent UI changes its key bindings | Bantay sends the wrong key |
| The wrong pane has focus | The decision goes to the wrong place |
| The prompt is not ready | The keystroke is lost or interpreted as text |
| The agent ignores the key | Bantay still reports delivery |
| A new prompt replaces the old one | The user may approve a different action |
| The transcript is ambiguous | The card may show the wrong request |
| The adapter process fails | The failure is ignored and the UI says delivered |
| Input synthesis is disabled | The standalone action returns early and the UI says delivered |
| The OpenCode decision file cannot be written | The write returns false and the approval path ignores it |

Liveness checks and fingerprinting reduce some risks. They do not close the loop. Bantay does not receive a decision result from the agent.

#### 5.1.1 Why the delivered state is not proof

`approveResult` checks pane liveness and accessibility. It then calls `approve` and returns `.delivered`.

`approveResult` returns `.failed` only when the pane is gone or Accessibility is missing. It never returns a transport failure. The card's Retry UI cannot recover a failed send.

`approve` calls `performAction`, which starts a detached task. The adapter methods return `Void`. No exit code, stderr, or agent response is observed.

`TmuxAdapter.sendKeys` discards the result of `runTmuxAsync`. `HerdrSocketAdapter.sendKeys` discards the result of its socket call and shell fallback.

`OpenCodeActionWriter.writeDecision` returns a Bool. `approve` ignores it.

`StandaloneAgentDispatcher.dispatchApproval` returns `Void`. It returns early when input synthesis is disabled.

The code comment in `AgentEventManager` says a failed send is never reported as success. The control flow contradicts that claim. A scheduled action is not a sent action. A sent action is not an accepted decision.

A delivered result dismisses the card and notification. A failed send can therefore remove the request from view.

This is the highest-priority defect in the product. It is also the clearest opportunity.

### 5.2 The MCP gap

`BantayMCPServer` exposes three tools: `bantay_set_status`, `bantay_request_approval`, and `bantay_log`.

`bantay_request_approval` does this:

1. Build the event payload.
2. Append the event to the JSONL event file.
3. Return "Approval requested for: title" immediately.

It does not wait for the user. It does not return the decision. It does not provide an idempotency key. It does not give the agent a way to resume.

That is an event injector, not an approval server. The README calls it an MCP server endpoint. The capability is real, but the approval semantics are not.

### 5.3 The hook gap

`ClaudeHookInstaller` builds a curl command that posts Claude hook JSON to `http://127.0.0.1:port/events`. It installs hooks for `PermissionPrompt`, `PermissionRequest`, `Stop`, `StopFailure`, and `Notification`.

The hook command does not return a Claude permission decision. Claude Code has no structured decision from Bantay. The prompt remains for the user or the keystroke path.

This is why the current approval flow can work in practice. It is also why it is fragile.

### 5.4 The feature truth table

| Capability | Bantay today | Needed for the wedge | Priority |
|---|---|---|---|
| Cross-agent status | Yes, broad | Keep | P0 |
| Approval queue | Yes | Keep | P0 |
| Transport delivery | Optimistic, not awaited | Confirmed send | P0 |
| Exact request display | Partial, parsing or payload | Structured payload | P0 |
| Structured decision round-trip | No | Yes | P0 |
| Agent acknowledgment | No | Yes | P0 |
| Decision receipt and audit | No | Yes | P0 |
| Policy engine | Partial, risky confirm | Scoped policy | P1 |
| Diff and plan context | Partial, peek and diff summary | Better context | P1 |
| Multi-select and free text | UI yes, mostly keystrokes | Structured transport | P0 |
| Remote decisions | ntfy actions | Native mobile later | P2 |
| External display fallback | Not documented | Documented fallback | P1 |
| Zero-config setup | No, script-heavy | Yes | P0 |
| Signed and notarized release | No release | Yes | P0 |
| Working Homebrew install | No, placeholder SHA | Yes | P0 |
| Public protocol docs | No | Yes | P1 |
| Team audit | No | Later | P2 |

### 5.5 Claims that should change

The current README and release materials make claims that the implementation does not fully support.

| Claim | Current problem | Better claim |
|---|---|---|
| Honest delivery with retry | The delivered state is optimistic. It does not prove a send or an agent decision. | "Decision receipts with agent acknowledgment" after the fix |
| Supports 30 agents | Approval support varies by transport | "Observe or decide support for each agent" |
| MCP approval server | The approval tool returns immediately | "MCP event bridge" until blocking approval ships |
| Homebrew install | The tap and release do not exist | "Build from source" until the release ships |
| Proprietary product | The repository is MIT | Resolve the license before release |
| Control plane | The product cannot yet control structured decisions | "Approval inbox" until the loop is closed |

This is not a marketing detail. These claims affect trust. Engineers will test them.

## 6. White space and positioning

### 6.1 Three category choices

| Choice | Description | Assessment |
|---|---|---|
| Notch monitor | Status, approvals, and jump for agents | Crowded, free, low price ceiling |
| All-in-one control plane | Agents, windows, tasks, quota, shelf, media | Too broad, competes with harnesses |
| Approval inbox and attention layer | One queue for decisions, context, proof, and audit | Narrow, painful, underserved |

The third choice is the best fit.

The monitor market is already served by free products with more agents and more distribution. The all-in-one control plane competes with T3 Code, Conductor, cmux, and the agent vendors. The approval inbox is narrow enough to win and important enough to pay for.

### 6.2 The promise

Recommended promise:

> The one thing that needs you.

Supporting line:

> One inbox for every coding agent. See the exact request. Decide once. Keep the receipt.

Alternative:

> Your agents have terminals. Give them a front desk.

The first promise is better. It describes attention filtering, not feature count.

### 6.3 The four pillars

| Pillar | User promise | Product requirement |
|---|---|---|
| Inbox | Every request in one place | Cross-agent, cross-terminal, remote |
| Context | Decide without hunting | Command, path, diff, repo, branch, risk |
| Proof | Know what happened | Agent acknowledgment, receipt, audit |
| Scriptable | Fit my setup | CLI, socket, hooks, open schema, MCP |

These four pillars are the product. The window manager, shelf, tasks, media, and quota are supporting features.

### 6.4 The target user

Primary user:

- Senior software engineer.
- macOS.
- Runs 2 to 5 agents each day.
- Uses a terminal, an IDE, or both.
- Has a homegrown notification script, tmux status, or cmux setup.
- Cares about local data and inspectable tools.
- Dislikes context switching.
- Wants control, not more automation.

Secondary user:

- Tech lead or small-team lead.
- Needs a record of agent actions and approvals.
- Cares about policy and audit.
- Will pay for team visibility later.

Not the primary user:

- Enterprise platform teams.
- Windows or Linux users.
- Non-technical vibe coders.
- People who want a full agent harness.
- People who want a general notch utility.

The primary user is the person who will test the claim. If Bantay convinces them, it can expand.

### 6.5 Jobs to be done

| Job | User language | Product response |
|---|---|---|
| Notice | Tell me when an agent needs me | One queue, one badge, one sound |
| Understand | Show me exactly what it wants | Command, path, diff, risk, agent |
| Decide | Let me approve or deny without finding the terminal | One key, one card, no context switch |
| Trust | Prove the agent got my decision | Acknowledgment and receipt |
| Recover | Tell me when delivery fails | Reason and retry |
| Extend | Let me script it | CLI, socket, hooks, schema |
| Review | Show me what happened while I was away | Digest and audit |

### 6.6 Positioning statement

For macOS engineers who run coding agents in terminals and IDEs, Bantay is the approval inbox that shows the one request that needs you. It captures the exact decision and proves what happened. Unlike notch dashboards that stop at status, Bantay closes the loop with structured approvals, policy, and an audit trail. It does not replace the agent or terminal.

### 6.7 What to de-emphasize

| Feature | Keep or cut | Reason |
|---|---|---|
| Window tiling | Keep as a power feature | It is unique but orthogonal to approvals |
| Shelf | Keep, hide in onboarding | Useful, not a reason to switch |
| Media controls | Keep, hide | Not relevant to the buyer |
| Tasks and Reminders | Keep, hide | Useful for some users, not the wedge |
| Quota | Keep, do not lead | Competitors already track usage |
| 30 agents | Do not lead | Claim only structured support |
| AI summaries | Avoid as authority | Models can hallucinate approvals |
| Multi-agent management | Do not lead | 68 percent prefer single-agent setups |

The product can keep these features. The marketing and onboarding should not lead with them.

## 7. Why engineers with homegrown tools would switch

This section answers the adoption question directly.

### 7.1 They will not switch wholesale

Engineers build their own tools because the tools encode their workflow, their trust boundaries, and their taste. A new app asks them to give up control. That is a high bar.

Stack Overflow reports that 34 percent of developers did not switch AI tools in the past year. Only 7.4 percent switched for better integration. The status quo is strong.

The cmux README makes the cultural point. It says the best developers have always built their own tools. It says closed products have not solved agent workflows. It says the developers closest to their codebases will figure it out first.

That is the audience Bantay wants. It will not win by telling them to stop building. It will win by giving them a better primitive.

The adoption motion is additive:

> Keep your scripts. Put a front desk on them.

### 7.2 Condition 1: Solve one painful moment better

The moment is specific. An agent blocks while the engineer is in another app. The engineer misses it, or switches to the terminal, reads the prompt, decides, and switches back. The cost is attention, not just time.

Bantay must make that moment fast and reliable. The target is under 5 seconds from block to decision, with no hunting.

Product requirements:

- One card per blocked agent.
- Exact command, path, or question.
- One key to approve, deny, or choose.
- No setup for the first agent.
- A visible result after the decision.

Metrics:

- Time from block to decision.
- Context switches per approval.
- Missed blocks per day.
- First-approval completion rate.

### 7.3 Condition 2: Do not take away control

The homegrown tool is inspectable and modifiable. A closed app is not. Engineers will ask three questions:

1. Can I see what it does?
2. Can I change what it does?
3. Can I remove it cleanly?

Bantay must answer yes to all three.

Product requirements:

- Source-available code or a public protocol.
- Local data export.
- CLI and socket API.
- Non-destructive hook install with preview.
- Clean uninstall.
- Signed and notarized builds.
- No telemetry by default.

This is why the license decision matters. A closed approval app asks engineers to trust a black box with their agent decisions. That is a hard sell to this audience.

### 7.4 Condition 3: Be honest about outcomes

Engineers will notice when an approval says done but the agent still waits. They will notice when a retry sends the wrong key. They will notice when the UI says "delivered" but nothing happened.

The current delivered state is optimistic. It can appear before the adapter action completes.

Bantay must separate three states:

| State | Meaning | UI label |
|---|---|---|
| Transport accepted | The adapter confirmed the send | Sent |
| Agent acknowledged | The agent accepted the decision | Accepted |
| Action completed | The tool ran or the turn resumed | Done |

If the product cannot prove state 2, it must not show state 3.

Product requirements:

- Blocking hooks or ACP for structured agents.
- Idempotency keys for retries.
- A receipt for every decision.
- A failure reason that names the exact cause.
- Retry only when the action is safe to repeat.

Metrics:

- False-success rate.
- Retry success rate.
- Approval reversal rate.
- User-reported mismatches.

This is the strongest differentiator. Free competitors have blocking hooks, but few expose the distinction between sent, accepted, and done. Bantay can own "proof."

### 7.5 Condition 4: Fit the existing stack

The engineer already has a stack. Bantay must fit it, not replace it.

| Layer | Must support |
|---|---|
| Agents | Claude Code, Codex, Cursor, Copilot, OpenCode, Gemini, Antigravity, Pi |
| Terminals | Ghostty, iTerm2, Terminal, Warp, WezTerm, Kitty, tmux, Zellij, Herdr, cmux |
| IDEs | VS Code, Cursor, Windsurf, Zed, JetBrains |
| Remote | SSH hosts |
| Scripts | Shell hooks, webhooks, CLI, socket |

Product requirements:

- Detect installed agents and terminals.
- Offer a non-destructive hook install.
- Show which agents support observe only and which support decisions.
- Keep the user's existing config intact.
- Provide a one-command uninstall.

The support matrix is a product artifact. It should be public and honest.

### 7.6 Condition 5: Save more time than it costs

The value must be obvious in the first session.

Illustrative model:

- 20 approvals per day.
- 15 seconds saved per approval.
- 5 minutes saved per day.
- 100 minutes saved per month.
- 100 US dollars per hour.
- 167 US dollars saved per month.

This is a model, not a measurement. It shows why a 29 to 39 US dollar one-time price is easy to justify if the product works.

Product requirements:

- Setup under 2 minutes.
- First value under 5 minutes.
- No account.
- A local weekly value report.
- No vanity metrics.

The report should show approvals handled, median decision time, context switches avoided, and failures prevented. It should not claim productivity gains it cannot measure.

### 7.7 Condition 6: Be there when away, but do not leak code

Remote and mobile decisions are table stakes for some users. CodeIsland has iPhone and Watch. Vibe Island has iPhone push. Ping Island has SSH.

Bantay already has ntfy actions for approve, deny, and choice. That is a good start. It is not a native mobile experience.

Product requirements:

- End-to-end encrypted relay.
- Device pairing with revocation.
- Approve or deny only by default.
- No code content in push payloads.
- Audit every remote decision.
- Offline fallback.

Do not build a native mobile app before design partners ask for it. Use ntfy actions and SSH first.

### 7.8 Condition 7: Give me a way to extend it

Tinkerers want hooks, CLI, webhooks, and custom policy. If Bantay gives them that, they become contributors and advocates.

Product requirements:

- Public Attention Event schema.
- Unix socket and HTTP API.
- CLI with JSON output.
- Webhook forwarding.
- Plugin SDK.
- Example scripts for tmux, cmux, and shell hooks.
- Policy file format with import and export.

This is the ecosystem moat. A closed dashboard cannot match it.

### 7.9 The adoption ladder

| Stage | User action | Product proof |
|---|---|---|
| 1. Observe | Install and see all agents | No config, no account |
| 2. Act | Approve one request from the notch | Exact context and receipt |
| 3. Trust | Use it for a week | No false successes |
| 4. Extend | Write a hook or policy | CLI and schema work |
| 5. Recommend | Share with a teammate | Team audit or policy |

Each stage needs a metric. If stage 2 fails, nothing else matters.

### 7.10 The one-sentence answer

Engineers will switch when Bantay is the only place where every agent's request arrives with exact context, a reliable decision, and a receipt. They will also switch when it plugs into their scripts instead of replacing them.

## 8. Protocol strategy

### 8.1 The protocol stack

| Protocol | Purpose | Bantay use | Priority |
|---|---|---|---|
| ACP | Editor and IDE to agent | Structured permission requests | P0 |
| AG-UI | Agent to user-facing app | Interrupt and resume semantics | P1 |
| MCP | Agent to tools | Blocking approval tool | P1 |
| A2A | Agent to agent | Status and delegation later | P2 |
| OTel GenAI | Telemetry | Cost, latency, traces | P2 |
| OSC 9, 99, 777 | Terminal notifications | Fallback only | P2 |

### 8.2 Recommended architecture

```text
Agent (Claude, Codex, Cursor, OpenCode, ...)
  |
  |  ACP session/request_permission
  |  or blocking hook
  |  or MCP tool call
  v
Bantay Attention Gateway
  - normalize to Attention Event v1
  - apply policy
  - queue and show the card
  - capture the decision
  - wait for agent acknowledgment
  - write the receipt
  v
Agent acknowledgment and resume
```

The gateway is the product. The notch is one client of the gateway.

### 8.3 ACP

ACP standardizes communication between editors and coding agents. It defines `session/request_permission`. The agent sends a tool call, a list of options, and a session ID. The client returns a selected option ID or a cancelled outcome.

The options include:

- `allow_once`
- `allow_always`
- `reject_once`
- `reject_always`

This maps cleanly to Bantay's card actions and policy engine.

ACP is used by JetBrains, Zed, Neovim, Emacs, Qt Creator, Unity, and other clients. ACP agents include Claude Agent, Codex CLI, Cursor, GitHub Copilot, Gemini CLI, OpenCode, Pi, and others.

ACP is the best path to structured approvals without reverse-engineering terminal UIs. The caveat is that ACP is editor-centric. Bantay would be a client, not an observer. It can host agents it launches. For existing terminal sessions, blocking hooks remain necessary.

### 8.4 AG-UI

AG-UI standardizes how agents connect to user-facing applications. It defines an interrupt-aware run lifecycle.

A run can end with an interrupt outcome. Each interrupt includes an ID, a reason, a message, a tool call ID, a response schema, an expiry, metadata, and an optional subagent ID. The client resumes with the same thread ID and interrupt ID. The payload is validated against the schema.

AG-UI supports:

- Approve with edits.
- Parallel interrupts.
- Non-tool input requests.
- Idempotent resume.
- Expiry.
- Full audit examples.

This is exactly the semantics Bantay needs. Bantay can expose an AG-UI endpoint and map interrupts to cards. It can also use AG-UI concepts internally for its own event model.

The caveat is scope. AG-UI is broader than a notch app. Bantay should use the interrupt and resume subset, not rebuild the whole framework.

### 8.5 MCP

MCP standardizes how agents access tools and data. MCP tools are model-controlled. The specification advises clients to keep a human in the loop and to let users deny tool calls.

MCP also defines elicitation, which lets a server request structured input from a user. Elicitation responses can be accept, decline, or cancel. It is not a security boundary. The specification warns servers not to request sensitive information.

Bantay's current MCP approval tool is fire-and-forget. The fix is a blocking tool call:

```json
{
  "name": "bantay_request_approval",
  "arguments": {
    "title": "Run tests",
    "details": "npm test in ~/project",
    "options": ["Allow once", "Deny"],
    "timeoutSeconds": 300
  }
}
```

The result should include the decision, the option ID, the reason, the receipt ID, and the agent acknowledgment. The call should be idempotent and safe to retry.

A blocking tool call is simpler and more portable than elicitation. Elicitation can be an optional adapter later.

### 8.6 A2A and OTel

A2A is for communication between agents. It is not a human approval protocol. Bantay can use A2A later to show which agent delegated work to which agent. It should not use A2A for decisions.

OpenTelemetry GenAI semantic conventions moved to a separate repository. They are useful for traces, token usage, latency, and cost. They are not an approval protocol. Bantay can export OTel data later for team observability.

### 8.7 Protocol priority

| Priority | Work | Why |
|---|---|---|
| P0 | Blocking hooks for Claude Code, Codex, OpenCode | Covers the top agents and proves the loop |
| P0 | Attention Event v1 and Decision Receipt v1 | Creates a stable contract |
| P1 | ACP client for launched agents | Structured permissions without terminal parsing |
| P1 | AG-UI interrupt adapter | Standard external contract for attention |
| P1 | MCP blocking approval | Makes the MCP server real |
| P2 | A2A status and OTel export | Observability, not the wedge |

### 8.8 Attention Event v1 sketch

```json
{
  "v": 1,
  "id": "evt_01",
  "source": "claude-code",
  "session": {
    "id": "sess_01",
    "cwd": "~/project",
    "repo": "github.com/acme/project",
    "branch": "main",
    "terminal": "ghostty",
    "pane": "0:1"
  },
  "kind": "approval",
  "title": "Run tests",
  "detail": "npm test",
  "risk": "low",
  "options": [
    { "id": "allow-once", "label": "Allow once", "kind": "allow_once" },
    { "id": "reject-once", "label": "Deny", "kind": "reject_once" }
  ],
  "expiresAt": "2026-10-25T12:00:00Z",
  "reply": {
    "mode": "blocking",
    "transport": "http",
    "endpoint": "http://127.0.0.1:41817/decision"
  },
  "meta": {
    "agentVersion": "1.2.3",
    "policy": "manual"
  }
}
```

The schema should be public and versioned. It should be independent of Bantay's internal Swift types.

### 8.9 Decision Receipt v1 sketch

```json
{
  "v": 1,
  "receiptId": "rcpt_01",
  "requestId": "evt_01",
  "requestHash": "sha256:...",
  "agent": "claude-code",
  "sessionId": "sess_01",
  "cwd": "~/project",
  "tool": "Bash",
  "command": "npm test",
  "risk": "low",
  "policy": "manual",
  "decision": "allow_once",
  "reason": null,
  "actor": "local-user",
  "decidedAt": "2026-10-25T12:00:02Z",
  "transport": "acp",
  "agentAck": "accepted",
  "idempotencyKey": "dec_01"
}
```

The receipt is the artifact that makes the product auditable. It is also the basis for team features.

## 9. Trust, safety, and honesty

### 9.1 Approvals are not safety

OWASP lists prompt injection and excessive agency as top risks for LLM applications. Simon Willison's lethal trifecta describes the dangerous combination of private data, untrusted content, and external communication. An approval UI cannot make an agent safe. It can make the human informed and the decision auditable.

Bantay should never claim that its approvals make agents safe. It should claim:

- Informed consent.
- Policy enforcement.
- An audit trail.
- A clear warning when context is untrusted.

The card should show the exact action. It should not show a model-generated summary as the primary evidence.

### 9.2 Approval fatigue

More prompts do not equal more safety. Users click through. The product must reduce prompt volume where it is safe and increase friction where it matters.

Recommended policy behavior:

| Risk | Default |
|---|---|
| Read-only file access inside the repo | Allow and record |
| Write inside the repo | Confirm once per session or scope |
| Destructive command | Always confirm |
| Network access | Confirm |
| Secret access | Deny or require Touch ID |
| Unknown tool | Review only |

The policy engine should show why a request matched a rule. It should support allow, deny, confirm, scope, and expiry. It should record every automatic decision.

### 9.3 Decision receipt

The receipt should include:

- Receipt ID.
- Request ID.
- Request hash.
- Agent and session.
- Working directory, repo, and branch.
- Tool and command or path.
- Risk and policy.
- Decision and reason.
- Actor and timestamp.
- Transport.
- Agent acknowledgment.
- Idempotency key.

The log should be append-only. A hash chain can make tampering detectable. The log should support JSON and CSV export. It should redact secrets by default. It should have retention settings.

This is the clearest product gap. None of the free competitors expose a decision receipt. ClaudeNotch has spend caps. CodeIsland has webhook forwarding. Neither is an audit product.

### 9.4 Failure semantics

The UI must separate transport, acknowledgment, and completion.

| State | Proof | UI |
|---|---|---|
| Sent | Bantay posted the decision | Sent |
| Accepted | The agent returned a decision result | Accepted |
| Done | The tool ran or the turn resumed | Done |
| Failed | The transport or agent returned an error | Failed with reason |

If Bantay only has proof of "Sent," it must not show "Done."

Retry should be safe. If the action is not idempotent, Bantay should open the terminal and explain why it cannot retry.

### 9.5 Security hardening

| Control | Requirement |
|---|---|
| Network | Bind to 127.0.0.1 and Unix sockets only |
| Tokens | Use headers, not query strings |
| Token comparison | Constant time |
| Release | Signed, notarized, SHA256 published |
| Actions | Pin third-party actions by SHA |
| Telemetry | Off by default, opt-in, documented |
| Logs | Redact secrets and command arguments |
| Permissions | Request only what the feature needs |
| Audit | Append-only, exportable, tamper-evident |
| Disclosure | Public security policy and threat model |

The Claude hook puts the token in the query string. The ingest server accepts that form and a bare-line token form. Query strings can appear in logs. Move the hook to a header or the bare-line form. The local-only binding is good. Keep it.

## 10. Licensing and business model

### 10.1 Current state

The repository is public MIT. The LICENSE names "Notchly contributors" and "Bantay-TUI contributors." All human commits are by the owner. There are 236 commits, one human contributor, no releases, no tags, 0 stars, 0 forks, and 3 open issues.

The stated strategy is proprietary. That is a contradiction.

MIT is irrevocable for existing copies. The owner can relicense future versions. The owner cannot revoke rights already granted. Because there are no releases, the practical exposure is low. The time to decide is now, before the first public release.

If other contributors join, use a Contributor License Agreement or a Developer Certificate of Origin with a relicense plan.

This is not legal advice. Consult a lawyer before changing the license.

### 10.2 License options

| Option | Adoption | Control | Monetization | Fit |
|---|---|---|---|---|
| Stay MIT | High | Low | Hard for a local app | Community and reputation |
| Source-available | Medium to high | Medium | Commercial license | Best fit for this audience |
| Closed source | Low to medium | High | Direct sales | Weak trust fit |
| Open-core | High | Medium | Team and cloud features | Good if the boundary is clear |

Source-available licenses to consider include FSL-1.1-MIT, BUSL-1.1, and PolyForm Noncommercial. FSL converts to MIT after two years and prohibits competing hosted services. BUSL has a change date and an additional use grant. PolyForm Noncommercial is simple but can scare engineers who use the tool at work.

Recommendation:

- If proprietary is non-negotiable, choose source-available and keep the protocol and schema under Apache-2.0 or CC-BY-4.0.
- If community adoption is the priority, choose open-core. Keep the local app open. Sell team audit, policy sync, and support.
- Do not stay MIT and call the product proprietary.

### 10.3 Pricing anchors

| Product | Price | Model |
|---|---|---|
| Vibe Island | 19.99 USD | One-time, 1 Mac, 1 year updates |
| AgentNotch | 9.99 USD | One-time, 14-day trial |
| Crest | 14.99 USD | One-time |
| CodeIsland | Free | MIT |
| Open Island | Free | GPL-3.0 |
| Ping Island | Free | Apache-2.0 |
| ClaudeNotch | Free for noncommercial | Source-available |
| Heard | 24 USD per month | Subscription, yearly billing |
| Conductor | 50 USD per month Pro, 60 USD per user per month Teams | Free local, paid cloud and team |
| T3 Code | Free | Open source |

Local monitoring is free or 10 to 20 US dollars one-time. Recurring revenue requires cloud, team, audit, or a managed service.

Recommended pricing:

| Tier | Price | Features |
|---|---|---|
| Free | 0 USD | Observe, one agent, manual approvals |
| Pro | 29 to 39 USD one-time | All agents, structured approvals, audit, policy, updates for 1 year |
| Team | 8 to 12 USD per seat per month | Shared policy, audit retention, admin, SSO later |

Do not charge for more agents or more notifications. Charge for trust, time, and team scope.

A 29 to 39 US dollar one-time price is defensible against 9.99 to 19.99 competitors if Bantay offers structured approvals, audit, and policy. A subscription for a local-only UI is not.

### 10.4 Business model fit

A solo founder, a macOS-only product, and free open-source competitors point to a small profitable product, not a venture-scale rocket. The plausible path is prosumer one-time revenue plus a team audit subscription.

A pure paid notch app at 19.99 US dollars has a low ceiling. The audit and policy layer is the expansion path. If the goal is a large company, the product must become a team security and audit platform. That is a different roadmap.

## 11. Distribution and go-to-market

### 11.1 Step zero: ship

The current release path is not usable.

| Problem | Evidence | Fix |
|---|---|---|
| No release | GitHub releases API returns 0 | Run the release workflow |
| No tag | GitHub tags API returns 0 | Create a signed tag |
| Placeholder Cask SHA | `Cask/bantay-tui.rb` | Generate the real SHA |
| Missing tap repository | `8-BitRhyon/homebrew-bantay-tui` does not exist | Create the tap or use an official cask |
| Release workflow never run | GitHub Actions has no release runs | Test on a clean Mac |
| No in-app updater | No Sparkle or equivalent | Add an in-app updater or document brew upgrade |

Without this, positioning work has no effect.

### 11.2 Website and demo

The website should answer five questions in one screen.

1. What is it?
2. Which agents does it work with?
3. What happens when an agent needs me?
4. Where does my data go?
5. How do I install it?

Recommended assets:

- A 20-second demo. Agent blocks. The notch shows the exact command. The user presses Y. A receipt appears.
- A support matrix. Observe or decide for each agent.
- A data flow diagram. Local only by default.
- A one-command install.
- A comparison page based on reproducible tests.
- A security page.

Do not use a generic dashboard screenshot. Show the moment of decision.

### 11.3 Developer channels

| Channel | Use |
|---|---|
| Hacker News | Show HN with a technical post on decision receipts |
| Reddit | r/ClaudeAI, r/ClaudeCode, r/codex, r/macapps, r/swift |
| X | Short demos and design partner stories |
| YouTube | Migration from tmux scripts and audit walkthroughs |
| Newsletters | Swift, macOS, and AI coding newsletters |
| Podcasts | Indie Mac and AI coding shows |
| GitHub | README, releases, discussions, roadmap |
| Homebrew | Official cask or a maintained tap |
| Product Hunt | After a polished release, not before |

### 11.4 Design partners

Recruit 10 to 20 senior engineers who run agents daily and have homegrown scripts.

Criteria:

- macOS.
- 2 or more agents.
- Terminal or IDE workflow.
- Cares about local data.
- Willing to give weekly feedback.

Offer free Pro, direct support, and influence over the roadmap.

Observe four moments:

1. Install.
2. First approval.
3. First failure.
4. First audit review.

Ask two questions:

- What would make you delete your script?
- What would make you uninstall Bantay?

Convert the best partners into case studies and referrals.

### 11.5 Content moat

Publish artifacts that competitors cannot easily copy:

- The Attention Event v1 specification.
- The Decision Receipt v1 specification.
- A reproducible test for approval honesty.
- A benchmark of approval latency and false-success rate.
- A migration guide from tmux, cmux, and native notifications.
- A security and privacy page.

This builds credibility with tinkerers. It also makes Bantay the reference implementation of the category.

### 11.6 Metrics

| Stage | Metric | Target |
|---|---|---|
| Activation | Install to first successful approval | 60 percent or more |
| Time to value | First approval | Under 5 minutes |
| Reliability | False-success rate | Under 0.1 percent |
| Reliability | Retry success rate | 90 percent or more |
| Speed | Median decision time | Under 5 seconds |
| Retention | 7-day active | 40 percent or more |
| Retention | 30-day active | 25 percent or more |
| Engagement | Approvals per user per week | 20 or more |
| Breadth | Agents per user | 2 or more |
| Support | Tickets per 100 users | Under 5 per month |
| Quality | Crash-free sessions | 99.5 percent or more |
| Growth | Design partner referral rate | 30 percent or more |

These targets are starting points. Replace them with measured baselines after the beta.

Instrument locally with opt-in telemetry. Publish a privacy-respecting summary. Do not collect code or command content by default.

### 11.7 90-day plan

| Weeks | Work |
|---|---|
| 1 to 2 | Fix release pipeline, cask, notarization, and clean-Mac test |
| 1 to 2 | Add decision receipt and audit log |
| 1 to 2 | Add blocking hook for Claude Code |
| 3 to 4 | Add Codex and OpenCode structured approvals |
| 3 to 4 | Remove blind approve for unsupported agents |
| 3 to 4 | Publish Attention Event v1 |
| 5 to 8 | Add ACP client for launched agents |
| 5 to 8 | Add AG-UI interrupt adapter |
| 5 to 8 | Add MCP blocking approval |
| 5 to 8 | Add policy engine v1 |
| 9 to 12 | Run design partner beta |
| 9 to 12 | Build website, demo, comparison page |
| 9 to 12 | Test pricing and launch |

This is a target, not a promise. The P0 work is the release and the decision loop. Everything else can wait.

## 12. Product roadmap

### 12.1 P0: before public release

1. Structured approval transport for Claude Code, Codex, and OpenCode.
2. Decision receipt and audit log.
3. Observe-only fallback for unsupported agents.
4. Signed, notarized release with a working Homebrew install.
5. Zero-config hook install with preview and rollback.
6. Public support matrix.

### 12.2 P1: differentiation

1. ACP client for launched agents.
2. AG-UI interrupt adapter.
3. MCP blocking approval.
4. Policy engine v1.
5. Diff and plan context in the card.
6. External display fallback.
7. Weekly value report.

### 12.3 P2: expansion

1. Native mobile and remote approvals with end-to-end encryption.
2. Team audit, shared policy, and admin.
3. Webhooks and plugin SDK.
4. A2A status and OTel export.
5. Windows or Linux only if data supports it.

### 12.4 Non-goals

- A full agent harness.
- Model routing or a model proxy.
- Code editing.
- A general notch utility.
- AI-generated approval summaries as authority.
- Enterprise features before individual retention.

## 13. Risks and mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Free competitors copy the wedge | High | High | Move fast on receipts and protocol |
| Agent vendors bundle approvals | High | High | Stay neutral and cross-agent |
| A false approval causes damage | Medium | High | Policy, confirmation, audit, red team |
| Token or local server leak | Medium | High | Local binding, headers, constant-time checks |
| macOS notch changes | Medium | Medium | Non-notch fallback and test matrix |
| License challenge | Medium | High | Decide before release, use a CLA |
| Scope creep | High | High | One job, one roadmap, explicit non-goals |
| Support burden | High | Medium | Support matrix, observe-only fallback, docs |
| Low willingness to pay | Medium | High | One-time Pro plus team audit |
| Founder bandwidth | High | High | Narrow P0, no Windows or cloud early |

## 14. Decisions for the user

1. License: stay MIT, switch to source-available, or close the source?
2. Category: notch monitor, all-in-one control plane, or approval inbox?
3. Scope: keep the window manager, shelf, tasks, and media in the v1 story?
4. Pricing: 29 to 39 US dollars one-time, free plus team, or another model?
5. Protocol: invest in ACP and blocking hooks now, or keep terminal automation?
6. Release: ship in 2 weeks with observe-only fallback, or wait for full coverage?
7. User: individual prosumer first, or team audit first?
8. Mobile: build now, or use ntfy actions until design partners ask?

Recommended answers:

1. Source-available or open-core.
2. Approval inbox.
3. Keep them as power features, not the story.
4. One-time Pro plus team audit later.
5. ACP and blocking hooks now.
6. Ship in 2 weeks.
7. Individual first.
8. Use ntfy actions until pull.

## 15. Sources

All sources were accessed on 25 October 2026.

### 15.1 Market data

- JetBrains, "AI Coding Agents: Adoption Trends," Developer Ecosystem Survey 2026: https://blog.jetbrains.com/research/2026/08/ai-coding-agent-adoption-2026/
- Stack Overflow, Developer Survey 2026, AI chapter: https://survey.stackoverflow.co/2026/ai
- Stack Overflow, "Agents on a leash: Agentic AI remains mostly single-agent and monitored at work," 27 May 2026: https://stackoverflow.blog/2026/05/27/agents-on-a-leash-agentic-ai-remains-mostly-monitored-at-work/

### 15.2 Protocols

- Agent Client Protocol, introduction: https://agentclientprotocol.com/
- Agent Client Protocol, tool calls and permission requests: https://agentclientprotocol.com/protocol/v1/tool-calls
- Agent Client Protocol, agents: https://agentclientprotocol.com/get-started/agents
- Agent Client Protocol, clients: https://agentclientprotocol.com/get-started/clients
- AG-UI, overview: https://docs.ag-ui.com/
- AG-UI, interrupts: https://docs.ag-ui.com/concepts/interrupts
- A2A Protocol: https://a2a-protocol.org/latest/
- Model Context Protocol, specification 2025-06-18: https://modelcontextprotocol.io/specification/2025-06-18
- Model Context Protocol, elicitation: https://modelcontextprotocol.io/specification/2025-06-18/client/elicitation
- Model Context Protocol, tools: https://modelcontextprotocol.io/specification/2025-06-18/server/tools
- OpenTelemetry, Generative AI semantic conventions: https://opentelemetry.io/docs/specs/semconv/gen-ai/
- OpenTelemetry GenAI semantic conventions repository: https://github.com/open-telemetry/semantic-conventions-genai

### 15.3 Security and distribution

- OWASP, Top 10 for LLM Applications: https://genai.owasp.org/llm-top-10/
- Simon Willison, "The lethal trifecta for AI agents," 16 June 2025: https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/
- Apple, notarizing macOS software: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Homebrew, Cask Cookbook: https://docs.brew.sh/Cask-Cookbook

### 15.4 Competitors

- Vibe Island: https://vibeisland.app/
- Vibe Island comparison page: https://vibeisland.app/alternatives/
- CodeIsland: https://github.com/wxtsky/CodeIsland
- Open Island: https://github.com/Octane0411/open-vibe-island
- Ping Island: https://github.com/erha19/ping-island
- AgentNotch: https://www.agentnotch.app/
- AgentNotch features: https://www.agentnotch.app/features
- AgentNotch works with: https://www.agentnotch.app/works-with
- Crest: https://crestnotch.app/crest
- Crest pricing: https://crestnotch.app/pricing
- ClaudeNotch: https://github.com/rawsun007/claude-notch
- NotchAgent: https://github.com/ykushch/notchagent
- Heard: https://heard.dev/pricing
- Heard repository: https://github.com/heardlabs/heard
- T3 Code: https://github.com/pingdotgg/t3code
- T3 Code site: https://t3.codes/
- cmux: https://github.com/manaflow-ai/cmux
- Conductor: https://conductor.build/
- Conductor pricing: https://conductor.build/pricing

### 15.5 Repository and package data

- Bantay-TUI repository: https://github.com/8-BitRhyon/bantay-tui
- GitHub API repository metadata, releases, tags, and contributors: https://api.github.com/repos/8-BitRhyon/bantay-tui
- Homebrew cask API for Crest: https://formulae.brew.sh/api/cask/crest.json
- Homebrew cask API for cmux: https://formulae.brew.sh/api/cask/cmux.json
- Homebrew cask API for Codex: https://formulae.brew.sh/api/cask/codex.json
- Homebrew cask API for Claude Code: https://formulae.brew.sh/api/cask/claude-code.json

### 15.6 Local evidence

- `README.md`
- `ARCHITECTURE.md`
- `LICENSE`
- `Cask/bantay-tui.rb`
- `.github/workflows/release.yml`
- `Sources/BantayTUI/AgentEventManager.swift`
- `Sources/BantayTUI/ApprovalPromptResolver.swift`
- `Sources/BantayTUI/BantayMCPServer.swift`
- `Sources/BantayTUI/ClaudeHookInstaller.swift`
- `Sources/BantayTUI/EventIngestServer.swift`
- `Sources/BantayTUI/HookSdk.swift`
- `Sources/BantayTUI/KeyboardSynthesizer.swift`
- `Sources/BantayTUI/PlexerAdapter.swift`
- `Sources/BantayTUI/TmuxAdapter.swift`
- `Sources/BantayTUI/HerdrSocketAdapter.swift`
- `Sources/BantayTUI/ZellijAdapter.swift`
- `Sources/BantayTUI/NotchStatusView.swift`
- `Sources/BantayTUI/ApprovalCardView.swift`
- `Sources/BantayTUI/SettingsView.swift`

## Appendix A: What to build first

| Order | Build | Proof |
|---|---|---|
| 1 | Claude Code blocking hook | Agent receives the decision and returns a result |
| 2 | Decision receipt | Every action has a record |
| 3 | Observe-only fallback | No blind approve for unsupported agents |
| 4 | Release pipeline | A clean Mac can install and run |
| 5 | Codex and OpenCode blocking hooks | Top three agents covered |
| 6 | Policy v1 | Low-risk reads auto-allow with audit |
| 7 | Attention Event v1 | External tools can integrate |
| 8 | ACP client | Structured permissions for launched agents |

## Appendix B: What to measure in design partner trials

| Question | Measure |
|---|---|
| Can they install it? | Setup completion rate and time |
| Do they trust it? | False-success reports and audit reviews |
| Do they use it? | Approvals per week and agents per user |
| Does it save time? | Median decision time and context switches |
| Would they pay? | Price acceptance and feature trade-offs |
| Would they recommend it? | Referral rate and testimonials |

## Appendix C: Research questions still open

1. How many approvals does a typical heavy agent user handle each day?
2. What is the real false-success rate of terminal keystroke approvals?
3. Do engineers prefer a notch card or a menu bar panel for approvals?
4. Will users pay for audit if they work alone?
5. Does ACP work for existing terminal sessions, or only for launched agents?
6. How often do agents support blocking hooks across versions?
7. What is the retention difference between observe-only and structured approval users?
8. How much does remote approval increase daily use?
9. Which agent vendors are likely to bundle a native approval inbox?
10. What license best balances adoption and commercial control for this audience?

## Appendix D: One-page answer

Bantay should not try to be the best notch app. It should try to be the most trustworthy approval inbox for engineers who already run agents.

The product promise is:

> The one thing that needs you.

The product proof is:

> Every decision has a receipt.

The product stance is:

> Keep your terminal. Keep your scripts. Bantay closes the loop.

The first build is not more agents. It is a blocking Claude Code hook, a decision receipt, an observe-only fallback, and a signed release.

The first customer is not a team. It is a senior macOS engineer who runs 2 to 5 agents and already built a notification script.

The first moat is not the notch. It is the decision graph: request, context, policy, decision, acknowledgment, audit.

That is the defensible answer to "why would other engineers switch?"
