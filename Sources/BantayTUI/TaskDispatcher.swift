import AppKit
import Foundation

/// Controller for dispatching task prompts directly to target AI agents
/// across multiplexer panes (herdr, tmux, zellij) or desktop IDE apps.
@MainActor
public final class TaskDispatcher: ObservableObject {
    public static let shared = TaskDispatcher()

    private init() {}

    /// Whether task dispatch is currently allowed under the active budget policy.
    public static func isDispatchAllowed(
        cost: Double,
        budget: Double,
        enforceLimit: Bool
    ) -> Bool {
        guard enforceLimit else { return true }
        let safeBudget = max(budget, 0.5)
        return cost < safeBudget
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _quarantineMap: [String: Date] = [:]

    /// Quarantined provider IDs whose cooldown has not yet expired.
    public static var activeQuarantinedProviders: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        _quarantineMap = _quarantineMap.filter { $0.value > now }
        return Set(_quarantineMap.keys)
    }

    /// Records rate limit or 429 event to temporarily quarantine provider.
    public static func recordRateLimitCooldown(
        provider: String,
        cooldownSeconds: TimeInterval = 300
    ) {
        lock.lock()
        defer { lock.unlock() }
        let canonical = canonicalAgentAlias(provider)
        _quarantineMap[canonical] = Date().addingTimeInterval(cooldownSeconds)
    }

    // Quota-aware fallback chains per agent
    private static let fallbackChains: [String: [String]] = [
        "claude": ["codex", "antigravity", "cursor", "ollama"],
        "codex": ["claude", "antigravity", "cursor", "ollama"],
        "cursor": ["claude", "codex", "antigravity", "ollama"],
        "antigravity": ["claude", "codex", "cursor", "ollama"],
        "cloudcode": ["antigravity", "codex", "claude", "ollama"],
        "windsurf": ["cursor", "claude", "codex", "antigravity"],
    ]

    /// Resolves target agent respecting quota saturation and quarantine cooldowns.
    public static func resolveQuotaAwareAgent(
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

    /// Dispatches a task to its assigned agent and returns the linked pane/target ID if successful.
    @discardableResult
    public func dispatch(task: BantayTask) -> String? {
        if !Self.isDispatchAllowed(
            cost: AgentEventManager.shared.usage.costUSD,
            budget: NotchHUDConfig.shared.dailyBudgetUSD,
            enforceLimit: NotchHUDConfig.shared.enforceBudgetLimit
        ) {
            return nil
        }

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
                dispatchToPane(
                    paneId: previousPane,
                    agentName: agentName,
                    promptText: promptText,
                    cwd: liveAgent.cwd
                )
                return previousPane
            }
            // Previous pane died/closed; fall through to resolve a live target
        }

        // 2. Search for an active agent snapshot matching the canonical agent name
        let matchingSnapshot = activeAgents.first {
            $0.source.lowercased() == agentName || $0.id.lowercased().contains(agentName)
        }

        let targetPaneID: String?
        if let paneId = matchingSnapshot?.paneId, !paneId.isEmpty {
            targetPaneID = paneId
            dispatchToPane(
                paneId: paneId,
                agentName: agentName,
                promptText: promptText,
                cwd: matchingSnapshot?.cwd
            )
        } else if agentName == "antigravity" || agentName == "codex" || agentName == "cursor"
            || agentName == "cloudcode" || agentName == "windsurf"
        {
            targetPaneID = "app:\(agentName)"
            StandaloneAgentDispatcher.dispatchPrompt(
                agentName: agentName, text: promptText, cwd: matchingSnapshot?.cwd, autoSend: true
            )
        } else {
            // Fallback to standalone dispatcher for plain terminals
            targetPaneID = "standalone:\(agentName)"
            StandaloneAgentDispatcher.dispatchPrompt(
                agentName: agentName, text: promptText, cwd: matchingSnapshot?.cwd, autoSend: true
            )
        }

        return targetPaneID
    }

    /// Dispatches prompt text to a designated pane, routing through active multiplexer or desktop agent.
    func dispatchToPane(
        paneId: String,
        agentName: String,
        promptText: String,
        cwd: String?
    ) {
        if paneId.hasPrefix("standalone:") {
            let clean = StandaloneAgentDispatcher.cleanAgentName(from: paneId)
            StandaloneAgentDispatcher.dispatchPrompt(
                agentName: clean, text: promptText, cwd: cwd, autoSend: true
            )
        } else if OpenCodeActionWriter.isOpenCodePane(paneId) {
            StandaloneAgentDispatcher.dispatchPrompt(
                agentName: "opencode", text: promptText, cwd: cwd, autoSend: true
            )
        } else {
            let activeAdapter = AgentEventManager.shared.activeAdapter
            activeAdapter.sendLine(paneId: paneId, text: promptText)
            if NotchHUDConfig.shared.focusTerminalOnDispatch {
                activeAdapter.focusPane(paneId: paneId)
            }
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
