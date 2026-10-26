import AppKit
import Foundation

/// Controller for dispatching task prompts directly to target AI agents
/// across multiplexer panes (herdr, tmux, zellij) or desktop IDE apps.
@MainActor
public final class TaskDispatcher: ObservableObject {
    public static let shared = TaskDispatcher()

    private init() {}

    /// Whether task dispatch is currently allowed under the active budget policy.
    nonisolated public static func isDispatchAllowed(
        cost: Double,
        budget: Double,
        enforceLimit: Bool
    ) -> Bool {
        guard enforceLimit else { return true }
        let safeBudget = max(budget, 0.5)
        return cost < safeBudget
    }

    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var _quarantineMap: [String: Date] = [:]

    /// Quarantined provider IDs whose cooldown has not yet expired.
    nonisolated public static var activeQuarantinedProviders: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        _quarantineMap = _quarantineMap.filter { $0.value > now }
        return Set(_quarantineMap.keys)
    }

    /// Records rate limit or 429 event to temporarily quarantine provider.
    nonisolated public static func recordRateLimitCooldown(
        provider: String,
        cooldownSeconds: TimeInterval = 300
    ) {
        lock.lock()
        defer { lock.unlock() }
        let canonical = canonicalAgentAlias(provider)
        _quarantineMap[canonical] = Date().addingTimeInterval(cooldownSeconds)
    }

    // Quota-aware fallback chains per agent
    nonisolated private static let fallbackChains: [String: [String]] = [
        "claude": ["codex", "antigravity", "cursor", "ollama"],
        "codex": ["claude", "antigravity", "cursor", "ollama"],
        "cursor": ["claude", "codex", "antigravity", "ollama"],
        "antigravity": ["claude", "codex", "cursor", "ollama"],
        "cloudcode": ["antigravity", "codex", "claude", "ollama"],
        "windsurf": ["cursor", "claude", "codex", "antigravity"],
    ]

    /// Resolves target agent respecting quota saturation and quarantine cooldowns.
    nonisolated public static func resolveQuotaAwareAgent(
        preferredAgent: String,
        quotas: [ProviderQuota],
        quarantinedProviders: Set<String> = []
    ) -> (agent: String, reroutedFrom: String?) {
        let canonical = canonicalAgentAlias(preferredAgent)
        func isBlocked(_ name: String) -> Bool {
            if quarantinedProviders.contains(name) { return true }
            if let q = quotas.first(where: { $0.id == name }), q.isCritical || q.isCooldown {
                return true
            }
            return false
        }

        if !isBlocked(canonical) {
            return (agent: canonical, reroutedFrom: nil)
        }

        let candidates = fallbackChains[canonical] ?? ["claude", "codex", "antigravity"]
        for candidate in candidates {
            if !isBlocked(candidate) {
                return (agent: candidate, reroutedFrom: canonical)
            }
        }

        return (agent: canonical, reroutedFrom: nil)
    }

    /// Dispatches a task to its assigned agent and returns the linked
    /// pane/target ID plus who actually received it (differs from the
    /// assignment when quota routing diverted it; nil pane means delivery
    /// failed, never silent success).
    @discardableResult
    public func dispatch(task: BantayTask) -> (paneID: String?, actualAgent: String?) {
        if !Self.isDispatchAllowed(
            cost: AgentEventManager.shared.usage.costUSD,
            budget: NotchHUDConfig.shared.dailyBudgetUSD,
            enforceLimit: NotchHUDConfig.shared.enforceBudgetLimit
        ) {
            return (nil, nil)
        }
        // NOTE: every failure return below keeps `resolution.agent`: callers
        // and harnesses can see who WOULD have received the task.

        let rawAgent =
            task.assignedAgent
            ?? AgentDetector.canonicalNameFromCommand(task.title)
            ?? "claude"
        let preferredAgent = Self.canonicalAgentAlias(rawAgent)
        let promptText = task.title

        let activeAgents = AgentEventManager.shared.agents
        let liveQuotas = QuotaAxiTracker.probeLiveQuotas(
            activeProviders: activeAgents.map(\.source),
            costUSD: AgentEventManager.shared.usage.costUSD,
            budgetUSD: NotchHUDConfig.shared.dailyBudgetUSD
        )
        let resolution = Self.resolveQuotaAwareAgent(
            preferredAgent: preferredAgent,
            quotas: liveQuotas,
            quarantinedProviders: Self.activeQuarantinedProviders
        )
        let agentName = resolution.agent

        // 1. If task already had a linked pane, verify that it is still alive in the active roster
        if let previousPane = task.linkedPaneID, !previousPane.isEmpty {
            if let liveAgent = activeAgents.first(where: { $0.paneId == previousPane }) {
                let delivered = dispatchToPane(
                    paneId: previousPane,
                    agentName: agentName,
                    promptText: promptText,
                    cwd: liveAgent.cwd
                )
                return delivered ? (previousPane, resolution.agent) : (nil, resolution.agent)
            }
            // Previous pane died/closed; fall through to resolve a live target
        }

        // 2. Search for an active agent snapshot matching the canonical agent name
        let matchingSnapshot = activeAgents.first {
            $0.source.lowercased() == agentName || $0.id.lowercased().contains(agentName)
        }

        let targetPaneID: String?
        let delivered: Bool
        if let paneId = matchingSnapshot?.paneId, !paneId.isEmpty {
            targetPaneID = paneId
            delivered = dispatchToPane(
                paneId: paneId,
                agentName: agentName,
                promptText: promptText,
                cwd: matchingSnapshot?.cwd
            )
        } else if agentName == "antigravity" || agentName == "codex" || agentName == "cursor"
            || agentName == "cloudcode" || agentName == "windsurf"
        {
            // Linked as the canonical standalone id so later pane events
            // (`standalone:<agent>:<project>`) match this task back.
            targetPaneID = "standalone:\(agentName)"
            delivered = StandaloneAgentDispatcher.dispatchPrompt(
                agentName: agentName, text: promptText, cwd: matchingSnapshot?.cwd, autoSend: true
            )
        } else {
            // Fallback to standalone dispatcher for plain terminals
            targetPaneID = "standalone:\(agentName)"
            delivered = StandaloneAgentDispatcher.dispatchPrompt(
                agentName: agentName, text: promptText, cwd: matchingSnapshot?.cwd, autoSend: true
            )
        }

        return delivered ? (targetPaneID, resolution.agent) : (nil, resolution.agent)
    }

    /// A pane event belongs to a linked task when the ids match exactly or
    /// the event pane extends the link (`standalone:antigravity` matches
    /// `standalone:antigravity:Portfolio`). Pure for harness coverage.
    nonisolated public static func paneMatches(linked: String, paneId: String) -> Bool {
        guard !linked.isEmpty, !paneId.isEmpty else { return false }
        if linked == paneId { return true }
        return paneId.hasPrefix(linked + ":") || paneId.hasPrefix(linked + "/")
    }

    /// Dispatches prompt text to a designated pane, routing through active multiplexer or desktop agent.
    /// Returns false when delivery failed (dead pane, no Accessibility,
    /// unreachable app) so tasks never read dispatched on a silent no-op.
    @discardableResult
    func dispatchToPane(
        paneId: String,
        agentName: String,
        promptText: String,
        cwd: String?
    ) -> Bool {
        if paneId.hasPrefix("standalone:") {
            let clean = StandaloneAgentDispatcher.cleanAgentName(from: paneId)
            return StandaloneAgentDispatcher.dispatchPrompt(
                agentName: clean, text: promptText, cwd: cwd, autoSend: true
            )
        } else if OpenCodeActionWriter.isOpenCodePane(paneId) {
            return StandaloneAgentDispatcher.dispatchPrompt(
                agentName: "opencode", text: promptText, cwd: cwd, autoSend: true
            )
        } else {
            let activeAdapter = AgentEventManager.shared.activeAdapter
            activeAdapter.sendLine(paneId: paneId, text: promptText)
            if NotchHUDConfig.shared.focusTerminalOnDispatch {
                activeAdapter.focusPane(paneId: paneId)
            }
            return true
        }
    }

    /// Normalizes agent aliases to canonical internal identifiers.
    nonisolated public static func canonicalAgentAlias(_ raw: String) -> String {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch lower {
        case "claude", "claude-code", "claude-agent", "claude-cli":
            return "claude"
        case "codex", "codex-cli", "codex-exec":
            return "codex"
        case "antigravity", "antigravity-ide", "antigravity-cli", "agy":
            return "antigravity"
        case "cursor", "cursor-agent", "cursor-cli":
            return "cursor"
        case "cloudcode", "cloud-code", "google-cloud-code":
            return "cloudcode"
        case "windsurf", "cascade", "windsurf-agent", "windsurf-ide":
            return "windsurf"
        case "copilot", "github-copilot":
            return "copilot"
        case "gemini", "gemini-cli":
            return "gemini"
        case "pi", "pi-agent":
            return "pi"
        case "herdr", "herdr-cli":
            return "herdr"
        case "kilo", "kilocode", "kilo-cli":
            return "kilo"
        case "openrouter", "open-router":
            return "openrouter"
        case "ollama", "ollama-cli":
            return "ollama"
        default:
            return lower
        }
    }
}
