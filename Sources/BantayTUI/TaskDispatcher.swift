import AppKit
import Foundation

/// Controller for dispatching task prompts directly to target AI agents
/// across multiplexer panes (herdr, tmux, zellij) or desktop IDE apps.
@MainActor
public final class TaskDispatcher: ObservableObject {
    public static let shared = TaskDispatcher()

    private let adapter = HerdrSocketAdapter()

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

    /// Dispatches a task to its assigned agent and returns the linked pane/target ID if successful.
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
        let agentName = Self.canonicalAgentAlias(rawAgent)
        let promptText = task.title

        let activeAgents = AgentEventManager.shared.agents

        // 1. If task already had a linked pane, verify that it is still alive in the active roster
        if let previousPane = task.linkedPaneID, !previousPane.isEmpty {
            let isStillLive = activeAgents.contains { $0.paneId == previousPane }
            if isStillLive {
                adapter.sendLine(paneId: previousPane, text: promptText)
                if NotchHUDConfig.shared.focusTerminalOnDispatch {
                    adapter.focusPane(paneId: previousPane)
                }
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
            adapter.sendLine(paneId: paneId, text: promptText)
            if NotchHUDConfig.shared.focusTerminalOnDispatch {
                adapter.focusPane(paneId: paneId)
            }
        } else if agentName == "antigravity" || agentName == "codex" || agentName == "cursor" {
            targetPaneID = "app:\(agentName)"
            StandaloneAgentDispatcher.dispatchPrompt(agentName: agentName, text: promptText)
        } else {
            // Fallback to standalone dispatcher for plain terminals
            targetPaneID = "standalone:\(agentName)"
            StandaloneAgentDispatcher.dispatchPrompt(agentName: agentName, text: promptText)
        }

        return targetPaneID
    }

    /// Normalizes agent aliases to canonical internal identifiers.
    public static func canonicalAgentAlias(_ raw: String) -> String {
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
        case "pi", "pi-agent":
            return "pi"
        case "herdr", "herdr-cli":
            return "herdr"
        case "kilo", "kilocode", "kilo-cli":
            return "kilo"
        default:
            return lower
        }
    }
}
