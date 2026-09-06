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
        let agentName = rawAgent.lowercased()
        let promptText = task.title

        let activeAgents = AgentEventManager.shared.agents
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
}
